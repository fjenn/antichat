/**
 * Candidate A: LegendList's KeyboardAwareLegendList on keyboard-controller's
 * KeyboardChatScrollView. Virtualised, not inverted. The library owns the
 * empty space under a pinned question (`anchoredEndSpace`) and the keyboard
 * choreography; this file only decides when to pin and when to let go.
 */
import React, {
  forwardRef,
  useCallback,
  useImperativeHandle,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import {StyleSheet} from 'react-native';
import {KeyboardController} from 'react-native-keyboard-controller';
import {
  KeyboardAwareLegendList,
  useKeyboardScrollToEnd,
} from '@legendapp/list/keyboard';

import {MessageRow} from './MessageRow';
import {shouldPinOnSend, shouldReleaseBlank} from './rules';
import type {Message} from './store';
import {PIN_OFFSET, type ChatListHandle, type ChatListProps} from './types';

type ListRef = React.ComponentRef<typeof KeyboardAwareLegendList>;

/** A landing scroll that fell short is repeated this often, this far apart. */
const LAND_ATTEMPTS = 5;
const LAND_RETRY_MS = 120;

const keyExtractor = (m: Message) => m.id;
const renderItem = ({item}: {item: Message}) => <MessageRow message={item} />;

export const ListA = forwardRef<ChatListHandle, ChatListProps>(
  function LegendChatList({messages, generating, composerHeight}, ref) {
    const listRef = useRef<NonNullable<ListRef>>(null);
    const {freeze, scrollMessageToEnd} = useKeyboardScrollToEnd({listRef});
    const [anchorIndex, setAnchorIndex] = useState<number | undefined>();
    const blank = useRef(0);
    const landed = useRef(false);
    const touched = useRef(false);
    const count = useRef(messages.length);
    const generatingRef = useRef(generating);
    generatingRef.current = generating;

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
      const state = listRef.current?.getState();
      const pin =
        !!state &&
        shouldPinOnSend({
          contentHeight: state.contentLength,
          viewportHeight: state.scrollLength - composerHeight.value,
          messageCount: before,
        });
      blank.current = 0;
      landed.current = false;
      touched.current = false;
      setAnchorIndex(pin ? userIndex : undefined);
      if (pin) {
        KeyboardController.dismiss().catch(() => {});
      } else {
        // Rule 2: nothing to pin; only make sure the new rows are in view.
        requestAnimationFrame(() => {
          scrollMessageToEnd({animated: true, closeKeyboard: true});
        });
      }
    }, [messages, composerHeight, scrollMessageToEnd]);

    // Rule 1: move the question to the top once the list has reserved the
    // space under it. The space reaches the native scroll view a few frames
    // after onReady, and until then a scroll is clamped at the old end, so
    // check where it landed and go again if it fell short.
    const land = useCallback((index: number, attempt = 0) => {
      const list = listRef.current;
      // A finger on the list ends the landing: the user decides from here.
      if (!list || touched.current || (attempt === 0 && landed.current)) {
        return;
      }
      landed.current = true;
      const state = list.getState();
      const target = Math.max(0, state.positionAtIndex(index) - PIN_OFFSET);
      if (Math.abs(state.scroll - target) <= 1) {
        return;
      }
      list.scrollToOffset({offset: target, animated: true});
      if (attempt < LAND_ATTEMPTS) {
        setTimeout(() => land(index, attempt + 1), LAND_RETRY_MS);
      }
    }, []);

    const anchoredEndSpace = useMemo(
      () =>
        anchorIndex === undefined
          ? undefined
          : {
              anchorIndex,
              anchorOffset: PIN_OFFSET,
              onSizeChanged: (size: number) => {
                blank.current = size;
              },
              onReady: () => land(anchorIndex),
            },
      [anchorIndex, land],
    );

    // Rule 3: once the reserved space is off screen after the answer finished,
    // drop it so scrolling back ends at the answer's last line.
    const onScroll = useCallback(() => {
      const state = listRef.current?.getState();
      if (
        state &&
        shouldReleaseBlank({
          generating: generatingRef.current,
          blank: blank.current,
          distanceFromEnd: state.distanceFromEnd,
        })
      ) {
        blank.current = 0;
        setAnchorIndex(undefined);
      }
    }, []);

    const onScrollBeginDrag = useCallback(() => {
      touched.current = true;
    }, []);

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
        const last = state.data.length - 1;
        const content =
          last >= 0 ? state.positionAtIndex(last) + state.sizeAtIndex(last) : 0;
        let user = last;
        while (user >= 0 && (state.data[user] as Message).role !== 'user') {
          user--;
        }
        const viewport = state.scrollLength - composerHeight.value;
        return {
          offset: state.scroll,
          viewport,
          content,
          blank: blank.current,
          lastUserTop:
            user >= 0 ? state.positionAtIndex(user) - state.scroll : null,
          endGap: state.scroll + viewport - content,
        };
      },
      scrollToOffset: (offset, animated) => {
        listRef.current?.scrollToOffset({offset, animated});
      },
      scrollToEnd: animated => {
        listRef.current?.scrollToEnd({animated});
      },
    }));

    return (
      <KeyboardAwareLegendList
        ref={listRef}
        testID="spike-list"
        style={styles.list}
        data={messages}
        keyExtractor={keyExtractor}
        renderItem={renderItem}
        estimatedItemSize={160}
        recycleItems={false}
        initialScrollAtEnd
        maintainVisibleContentPosition
        anchoredEndSpace={anchoredEndSpace}
        contentInsetEndAdjustment={composerHeight}
        freeze={freeze}
        keyboardLiftBehavior="whenAtEnd"
        keyboardDismissMode="interactive"
        keyboardShouldPersistTaps="handled"
        onScroll={onScroll}
        onScrollBeginDrag={onScrollBeginDrag}
        scrollEventThrottle={16}
      />
    );
  },
);

const styles = StyleSheet.create({list: {flex: 1}});
