/**
 * The conversation as a list. `KeyboardAwareLegendList` (the M0 decision)
 * virtualises the rows and owns the keyboard and the empty space under a
 * pinned question; this file decides when to pin, when to let the space go
 * and when the way back to the newest message is offered.
 *
 * The six rules: docs/research/01-chatgpt-mobile-audit.md §3.3.
 */
import React, {
  forwardRef,
  useCallback,
  useEffect,
  useImperativeHandle,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import {View} from 'react-native';
import {KeyboardController} from 'react-native-keyboard-controller';
import {
  Easing,
  cancelAnimation,
  runOnJS,
  scrollTo,
  useAnimatedReaction,
  useAnimatedRef,
  useReducedMotion,
  useSharedValue,
  withTiming,
  type SharedValue,
} from 'react-native-reanimated';
import type Animated from 'react-native-reanimated';
import {
  KeyboardAwareLegendList,
  useKeyboardScrollToEnd,
} from '@legendapp/list/keyboard';
import {StyleSheet} from 'react-native-unistyles';

import {shouldPinOnSend, shouldReleaseBlank} from './rules';
import {noteScroll, resetScrollPace} from './scrollPace';
import {ScrollToBottomButton} from './ScrollToBottomButton';
import type {ThreadRow, ThreadSnapshot} from './ThreadController';
import {ThreadRowView} from './ThreadRowView';

type ListRef = React.ComponentRef<typeof KeyboardAwareLegendList>;

/** Gap between the top bar and a pinned question. */
export const PIN_GAP = 4;
/** How far the end of the conversation may be below the fold before the button shows. */
const BOTTOM_BUTTON_AFTER = 96;
/** The pin animation: one move, the same on both platforms. */
const PIN_MS = 320;
const PIN_EASING = Easing.bezier(0.3, 0, 0.1, 1);

/** Geometry for the unattended scroll checks; same terms as the M0 spike. */
export interface ThreadMetrics {
  offset: number;
  /** Height between the top bar and the composer. */
  viewport: number;
  /** Height of the messages, without reserved empty space. */
  content: number;
  /** Empty space reserved under the newest answer. */
  blank: number;
  /** Top of the newest question, measured from under the top bar. */
  lastUserTop: number | null;
  /** Distance from the end of the messages to the top of the composer. */
  endGap: number;
}

export interface ThreadListHandle {
  metrics(): ThreadMetrics;
  scrollToOffset(offset: number, animated: boolean): void;
  scrollToLatest(animated: boolean): void;
}

export interface ThreadListProps {
  snapshot: ThreadSnapshot;
  /** Height of the composer dock, updated as it grows. */
  composerHeight: SharedValue<number>;
  /** Space the floating top bar takes at the top of the screen. */
  topInset: number;
}

const keyExtractor = (row: ThreadRow) => row.key;
const renderItem = ({item}: {item: ThreadRow}) => <ThreadRowView row={item} />;
const getItemType = (row: ThreadRow) => row.message.role;

export const ThreadList = forwardRef<ThreadListHandle, ThreadListProps>(
  function Thread({snapshot, composerHeight, topInset}, ref) {
    const listRef = useRef<NonNullable<ListRef>>(null);
    const {freeze, scrollMessageToEnd} = useKeyboardScrollToEnd({listRef});
    const [anchorIndex, setAnchorIndex] = useState<number | undefined>();
    const [awayFromLatest, setAwayFromLatest] = useState(false);
    const blank = useRef(0);
    const touched = useRef(false);
    const landing = useRef(0);
    const seenTurn = useRef(snapshot.turn);
    const landedTurn = useRef(snapshot.turn);
    const generating = useRef(snapshot.generating);
    generating.current = snapshot.generating;
    const anchor = useRef<number | undefined>(undefined);
    anchor.current = anchorIndex;
    const pinOffset = topInset + PIN_GAP;

    const {rows} = snapshot;
    // Rule 4: an old chat opens at its end. A chat that has just been
    // started opens at its first message, with the answer growing under it.
    const openAtEnd = useRef(!(snapshot.generating && rows.length <= 2));

    /** Where the messages end, and where the composer starts covering them. */
    const edges = useCallback(() => {
      const state = listRef.current?.getState();
      if (!state) {
        return null;
      }
      const last = state.data.length - 1;
      // The list counts positions from under its header (the top inset).
      const contentEnd =
        topInset +
        (last >= 0 ? state.positionAtIndex(last) + state.sizeAtIndex(last) : 0);
      const visible = state.scrollLength - composerHeight.value;
      return {state, contentEnd, visible};
    }, [composerHeight, topInset]);

    /** Is the end of the messages out of sight below the composer? */
    const checkLatest = useCallback(() => {
      const at = edges();
      if (at) {
        const below = at.contentEnd - (at.state.scroll + at.visible);
        setAwayFromLatest(below > BOTTOM_BUTTON_AFTER);
      }
    }, [edges]);

    // Rule 1: move the question to the top. The space under it reaches the
    // native scroll view a few frames after the list has reserved it, and a
    // scroll asked for before that is clamped at the old end (and an
    // animated one is dropped). So the move is driven from here, frame by
    // frame on the UI thread: early frames may be clamped, the following
    // ones catch up, and it is one motion either way.
    const scrollRef = useAnimatedRef<Animated.ScrollView>();
    const pinFrom = useSharedValue(0);
    const pinTo = useSharedValue(0);
    const pinProgress = useSharedValue(1);
    const pinning = useSharedValue(false);
    const reduceMotion = useReducedMotion();

    useAnimatedReaction(
      () => pinProgress.value,
      progress => {
        if (pinning.value) {
          scrollTo(
            scrollRef,
            0,
            pinFrom.value + (pinTo.value - pinFrom.value) * progress,
            false,
          );
        }
      },
    );

    const settle = useCallback(
      (index: number, ticket: number) => {
        const list = listRef.current;
        if (!list || ticket !== landing.current || touched.current) {
          return;
        }
        const state = list.getState();
        const target = Math.max(
          0,
          topInset + state.positionAtIndex(index) - pinOffset,
        );
        // The rows above can still change height while the move runs.
        if (Math.abs(state.scroll - target) > 1) {
          list.scrollToOffset({offset: target, animated: false});
        }
      },
      [pinOffset, topInset],
    );

    const land = useCallback(
      (index: number) => {
        const list = listRef.current;
        if (!list || touched.current) {
          return;
        }
        const state = list.getState();
        const target = Math.max(
          0,
          topInset + state.positionAtIndex(index) - pinOffset,
        );
        if (pinning.value) {
          // Already on its way: the list has measured the rows since.
          pinTo.value = target;
          return;
        }
        if (Math.abs(state.scroll - target) <= 1) {
          return;
        }
        const ticket = ++landing.current;
        list.cancelScroll();
        pinFrom.value = state.scroll;
        pinTo.value = target;
        pinning.value = true;
        pinProgress.value = 0;
        pinProgress.value = withTiming(
          1,
          {duration: reduceMotion ? 120 : PIN_MS, easing: PIN_EASING},
          finished => {
            pinning.value = false;
            if (finished) {
              runOnJS(settle)(index, ticket);
            }
          },
        );
      },
      [
        pinFrom,
        pinProgress,
        pinTo,
        pinning,
        pinOffset,
        reduceMotion,
        settle,
        topInset,
      ],
    );

    const stopPin = useCallback(() => {
      landing.current += 1;
      pinning.value = false;
      cancelAnimation(pinProgress);
    }, [pinProgress, pinning]);

    // A new turn: a question (or an edited one) and its empty answer.
    useLayoutEffect(() => {
      if (snapshot.turn === seenTurn.current) {
        return;
      }
      seenTurn.current = snapshot.turn;
      const index = rows.findIndex(row => row.key === snapshot.turnAnchorKey);
      const state = listRef.current?.getState();
      if (index < 0 || !state) {
        return;
      }
      // What was there before this turn: everything above the question.
      const before = topInset + state.positionAtIndex(index);
      const pin = shouldPinOnSend({
        contentHeight: before,
        viewportHeight: state.scrollLength - composerHeight.value,
        messageCount: index,
      });
      blank.current = 0;
      touched.current = false;
      stopPin();
      setAnchorIndex(pin ? index : undefined);
      if (pin) {
        KeyboardController.dismiss().catch(() => {});
        // Start at once towards where the question will be; `onReady`
        // corrects the target when the rows are measured.
        requestAnimationFrame(() => land(index));
      } else {
        // Rule 2: nothing to pin; only make sure the new rows are in view.
        requestAnimationFrame(() => {
          scrollMessageToEnd({animated: true, closeKeyboard: true}).catch(
            () => {},
          );
        });
      }
    }, [
      composerHeight,
      land,
      rows,
      scrollMessageToEnd,
      snapshot.turn,
      snapshot.turnAnchorKey,
      stopPin,
      topInset,
    ]);

    const anchoredEndSpace = useMemo(
      () =>
        anchorIndex === undefined
          ? undefined
          : {
              anchorIndex,
              anchorOffset: pinOffset,
              onSizeChanged: (size: number) => {
                blank.current = size;
                checkLatest();
              },
              onReady: () => {
                // Ready is announced again as the answer grows; the first
                // one carries the measured position of the question.
                if (landedTurn.current !== seenTurn.current) {
                  landedTurn.current = seenTurn.current;
                  land(anchorIndex);
                }
              },
            },
      [anchorIndex, checkLatest, land, pinOffset],
    );

    // Rule 3: once the reserved space is off screen after the answer is
    // done, drop it, so scrolling back ends at the answer's last line.
    const onScroll = useCallback(() => {
      const state = listRef.current?.getState();
      if (!state) {
        return;
      }
      noteScroll(state.scroll);
      if (
        anchor.current !== undefined &&
        shouldReleaseBlank({
          generating: generating.current,
          blank: blank.current,
          distanceFromEnd: state.distanceFromEnd,
        })
      ) {
        blank.current = 0;
        setAnchorIndex(undefined);
      }
      checkLatest();
    }, [checkLatest]);

    // An answer that outgrew its reserved space needs none any more.
    useEffect(() => {
      if (
        !snapshot.generating &&
        anchorIndex !== undefined &&
        blank.current === 0
      ) {
        setAnchorIndex(undefined);
      }
    }, [anchorIndex, snapshot.generating]);

    useEffect(() => resetScrollPace, []);

    // The answer grows without a scroll event; the button has to notice.
    useEffect(() => {
      const state = listRef.current?.getState();
      return state?.listen('totalSize', checkLatest);
    }, [checkLatest]);

    // A finger on the list ends the landing: the user decides from here.
    const onScrollBeginDrag = useCallback(() => {
      touched.current = true;
      stopPin();
    }, [stopPin]);

    const scrollToLatest = useCallback(
      (animated: boolean) => {
        const list = listRef.current;
        const at = edges();
        if (!list || !at) {
          return;
        }
        touched.current = true;
        stopPin();
        // The end of the answer on the composer's top edge...
        let offset = Math.max(0, at.contentEnd - at.visible);
        if (anchor.current !== undefined) {
          // ...unless the answer is shorter than the screen: then its
          // question stays at the top, with the empty space under it.
          offset = Math.max(
            offset,
            topInset + at.state.positionAtIndex(anchor.current) - pinOffset,
          );
        }
        list.scrollToOffset({offset, animated});
      },
      [edges, pinOffset, stopPin, topInset],
    );

    useImperativeHandle(ref, () => ({
      metrics: () => {
        const state = listRef.current?.getState();
        if (!state) {
          return {
            offset: 0,
            viewport: 0,
            content: 0,
            blank: 0,
            lastUserTop: null,
            endGap: 0,
          };
        }
        const data = state.data as readonly ThreadRow[];
        const last = data.length - 1;
        const content =
          topInset +
          (last >= 0
            ? state.positionAtIndex(last) + state.sizeAtIndex(last)
            : 0);
        let user = last;
        while (user >= 0 && data[user].message.role !== 'user') {
          user--;
        }
        const viewport = state.scrollLength - composerHeight.value - topInset;
        return {
          offset: state.scroll,
          viewport,
          content,
          blank: blank.current,
          lastUserTop:
            user >= 0 ? state.positionAtIndex(user) - state.scroll : null,
          endGap:
            state.scroll + state.scrollLength - composerHeight.value - content,
        };
      },
      scrollToOffset: (offset, animated) => {
        listRef.current?.scrollToOffset({offset, animated});
      },
      scrollToLatest,
    }));

    const header = useMemo(
      () => <View style={{height: topInset}} />,
      [topInset],
    );

    return (
      <View style={styles.fill}>
        <KeyboardAwareLegendList
          ref={listRef}
          refScrollView={scrollRef}
          testID="thread"
          style={styles.fill}
          data={rows as ThreadRow[]}
          keyExtractor={keyExtractor}
          renderItem={renderItem}
          getItemType={getItemType}
          estimatedItemSize={220}
          drawDistance={900}
          recycleItems={false}
          initialScrollAtEnd={openAtEnd.current}
          maintainVisibleContentPosition
          anchoredEndSpace={anchoredEndSpace}
          contentInsetEndAdjustment={composerHeight}
          freeze={freeze}
          keyboardLiftBehavior="whenAtEnd"
          keyboardDismissMode="interactive"
          keyboardShouldPersistTaps="handled"
          showsVerticalScrollIndicator={false}
          ListHeaderComponent={header}
          onScroll={onScroll}
          onScrollBeginDrag={onScrollBeginDrag}
          scrollEventThrottle={16}
        />
        <ScrollToBottomButton
          visible={awayFromLatest}
          composerHeight={composerHeight}
          onPress={() => scrollToLatest(true)}
        />
      </View>
    );
  },
);

const styles = StyleSheet.create({
  fill: {flex: 1},
});
