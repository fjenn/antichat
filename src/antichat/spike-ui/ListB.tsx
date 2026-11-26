/**
 * Candidate B: the Private Mind approach (software-mansion-labs/private-mind,
 * MIT; components/chat-screen/Messages.tsx and pinScroll.ts). A plain
 * KeyboardChatScrollView, not virtualised, showing a window of the latest
 * messages that grows as the user scrolls up. Pin-to-top is done by hand: the
 * last answer row gets a minimum height (the "floor") so the question can
 * reach the top, and the list scrolls there once the content is tall enough.
 */
import React, {
  forwardRef,
  useCallback,
  useImperativeHandle,
  useLayoutEffect,
  useRef,
  useState,
} from 'react';
import {
  StyleSheet,
  View,
  type LayoutChangeEvent,
  type NativeScrollEvent,
  type NativeSyntheticEvent,
} from 'react-native';
import {
  KeyboardChatScrollView,
  type KeyboardChatScrollViewRef,
} from 'react-native-keyboard-controller';
import {
  useAnimatedReaction,
  useSharedValue,
  withTiming,
} from 'react-native-reanimated';
import {runOnJS} from 'react-native-worklets';

import {MessageRow} from './MessageRow';
import {blankSpaceFor, shouldPinOnSend, shouldReleaseBlank} from './rules';
import {PIN_OFFSET, type ChatListHandle, type ChatListProps} from './types';

const WINDOW_INITIAL = 40;
const WINDOW_STEP = 40;
const WINDOW_TOP_TRIGGER = 600;
const PAD_TOP = 8;
const PAD_BOTTOM = 8;
const KEEP_ROW_ON_PREPEND = {minIndexForVisible: 0};

export const ListB = forwardRef<ChatListHandle, ChatListProps>(
  function ScrollViewChatList({messages, generating, composerHeight}, ref) {
    const scrollRef = useRef<KeyboardChatScrollViewRef>(null);
    const [first, setFirst] = useState(() =>
      Math.max(0, messages.length - WINDOW_INITIAL),
    );
    /** Minimum height of the last answer row while its question is pinned. */
    const [floor, setFloor] = useState(0);
    /** Composer height at rest; the list pads by it, growth goes to extraContentPadding. */
    const [basePad, setBasePad] = useState(0);
    const extraContentPadding = useSharedValue(0);

    const geo = useRef({
      offset: 0,
      viewport: 0,
      contentSize: 0,
      userTop: 0,
      userHeight: 0,
      answerNatural: 0,
      pendingPin: false,
      opening: true,
    }).current;
    const count = useRef(messages.length);
    const generatingRef = useRef(generating);
    generatingRef.current = generating;
    const floorRef = useRef(0);
    floorRef.current = floor;
    const basePadRef = useRef(0);
    basePadRef.current = basePad;

    // The bar's resting height becomes list padding; anything above it is
    // growth and goes to extraContentPadding (Private Mind's useBarGrowth).
    const base = useSharedValue(0);
    useAnimatedReaction(
      () => composerHeight.value,
      height => {
        if (height <= 0) {
          return;
        }
        if (base.value === 0 || height < base.value) {
          base.value = height;
          runOnJS(setBasePad)(height);
        }
        extraContentPadding.value = withTiming(
          Math.max(0, height - base.value),
          {
            duration: 160,
          },
        );
      },
    );

    const visibleHeight = () => geo.viewport - basePadRef.current;
    const blankNow = () => Math.max(0, floorRef.current - geo.answerNatural);
    const realContent = () => geo.contentSize - blankNow() - basePadRef.current;

    const tryPin = useCallback(() => {
      // userHeight is 0 until the new question has reported its own layout;
      // before that userTop still belongs to the previous question.
      if (!geo.pendingPin || geo.userHeight === 0) {
        return;
      }
      const target = Math.max(0, geo.userTop - PIN_OFFSET);
      // Reachable only once the floor has been laid out.
      if (geo.contentSize < target + geo.viewport - 1) {
        return;
      }
      geo.pendingPin = false;
      scrollRef.current?.scrollTo({y: target, animated: true});
    }, [geo]);

    // A send appends a question and an empty answer.
    useLayoutEffect(() => {
      const before = count.current;
      count.current = messages.length;
      const userIndex = messages.length - 2;
      if (
        messages.length !== before + 2 ||
        messages[userIndex]?.role !== 'user'
      ) {
        return;
      }
      const pin = shouldPinOnSend({
        contentHeight: realContent(),
        viewportHeight: visibleHeight(),
        messageCount: before,
      });
      geo.opening = false;
      geo.answerNatural = 0;
      geo.userHeight = 0;
      geo.pendingPin = pin;
      if (!pin) {
        setFloor(0);
        requestAnimationFrame(() =>
          scrollRef.current?.scrollToEnd({animated: true}),
        );
      }
      // The floor itself is set when the new question row reports its height.
      // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [messages]);

    const onUserLayout = useCallback(
      (event: LayoutChangeEvent) => {
        const {y, height} = event.nativeEvent.layout;
        geo.userTop = y;
        geo.userHeight = height;
        if (geo.pendingPin) {
          setFloor(
            blankSpaceFor({
              viewportHeight: visibleHeight(),
              pinOffset: PIN_OFFSET,
              questionHeight: height,
              answerHeight: 0,
              chrome: PAD_BOTTOM,
            }),
          );
          tryPin();
        }
      },
      // eslint-disable-next-line react-hooks/exhaustive-deps
      [geo, tryPin],
    );

    const onAnswerLayout = useCallback(
      (event: LayoutChangeEvent) => {
        geo.answerNatural = event.nativeEvent.layout.height;
        // An answer taller than the floor no longer needs it.
        if (floorRef.current > 0 && geo.answerNatural >= floorRef.current) {
          setFloor(0);
        }
      },
      [geo],
    );

    const onContentSizeChange = useCallback(
      (_w: number, h: number) => {
        geo.contentSize = h;
        if (geo.opening && geo.viewport > 0) {
          // Rule 4: an opened conversation rests at its end. Rows keep growing
          // for a few frames while their text is laid out natively, so stay at
          // the end until the user touches the list or sends.
          scrollRef.current?.scrollToEnd({animated: false});
        }
        tryPin();
      },
      [geo, tryPin],
    );

    const onScroll = useCallback(
      (event: NativeSyntheticEvent<NativeScrollEvent>) => {
        const {contentOffset, layoutMeasurement, contentSize} =
          event.nativeEvent;
        geo.offset = contentOffset.y;
        geo.viewport = layoutMeasurement.height;
        geo.contentSize = contentSize.height;
        if (contentOffset.y < WINDOW_TOP_TRIGGER) {
          setFirst(current => Math.max(0, current - WINDOW_STEP));
        }
        // Rule 3: let the floor go once its empty part has left the screen.
        const blank = blankNow();
        if (
          shouldReleaseBlank({
            generating: generatingRef.current,
            blank,
            distanceFromEnd:
              contentSize.height -
              basePadRef.current -
              (contentOffset.y + visibleHeight()),
          })
        ) {
          setFloor(0);
        }
      },
      // eslint-disable-next-line react-hooks/exhaustive-deps
      [geo],
    );

    const onScrollBeginDrag = useCallback(() => {
      geo.opening = false;
    }, [geo]);

    const onLayout = useCallback(
      (event: LayoutChangeEvent) => {
        geo.viewport = event.nativeEvent.layout.height;
      },
      [geo],
    );

    useImperativeHandle(ref, () => ({
      metrics: () => {
        const viewport = geo.viewport - composerHeight.value;
        const content = realContent();
        const hasUser = messages.some(m => m.role === 'user');
        return {
          offset: geo.offset,
          viewport,
          content,
          blank: blankNow(),
          lastUserTop: hasUser ? geo.userTop - geo.offset : null,
          endGap: geo.offset + viewport - content,
        };
      },
      scrollToOffset: (offset, animated) => {
        scrollRef.current?.scrollTo({y: offset, animated});
      },
      scrollToEnd: animated => {
        scrollRef.current?.scrollToEnd({animated});
      },
    }));

    const shown = messages.slice(first);
    let lastUser = shown.length - 1;
    while (lastUser >= 0 && shown[lastUser].role !== 'user') {
      lastUser--;
    }
    const lastAnswer =
      shown.length > 0 && shown[shown.length - 1].role === 'assistant'
        ? shown.length - 1
        : -1;

    return (
      <KeyboardChatScrollView
        ref={scrollRef}
        testID="spike-list"
        style={styles.list}
        contentContainerStyle={{
          paddingTop: PAD_TOP,
          paddingBottom: basePad + PAD_BOTTOM,
        }}
        // Rule 5: over reserved empty space the keyboard overlays; otherwise it
        // lifts the conversation only when the list rests at its end.
        keyboardLiftBehavior={floor > 0 ? 'never' : 'whenAtEnd'}
        extraContentPadding={extraContentPadding}
        keyboardDismissMode="interactive"
        keyboardShouldPersistTaps="handled"
        maintainVisibleContentPosition={KEEP_ROW_ON_PREPEND}
        onLayout={onLayout}
        onContentSizeChange={onContentSizeChange}
        onScroll={onScroll}
        onScrollBeginDrag={onScrollBeginDrag}
        scrollEventThrottle={16}>
        {shown.map((message, index) => (
          // Same wrappers for every row, so a row is not remounted when it stops
          // being the last question or answer.
          <View
            key={message.id}
            onLayout={index === lastUser ? onUserLayout : undefined}
            style={
              index === lastAnswer && floor > 0 ? {minHeight: floor} : undefined
            }>
            <View onLayout={index === lastAnswer ? onAnswerLayout : undefined}>
              <MessageRow message={message} />
            </View>
          </View>
        ))}
      </KeyboardChatScrollView>
    );
  },
);

const styles = StyleSheet.create({list: {flex: 1}});
