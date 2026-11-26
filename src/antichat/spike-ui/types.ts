import type {SharedValue} from 'react-native-reanimated';

import type {Message} from './store';

export type ListKind = 'A' | 'B';

/** Geometry the scroll-rule checks read, in the same terms for both lists. */
export type ListMetrics = {
  /** Scroll offset from the top of the content. */
  offset: number;
  /** Height of the visible list area. */
  viewport: number;
  /** Height of the real content (messages), without reserved empty space. */
  content: number;
  /** Empty space currently reserved under the last answer (rule 3). */
  blank: number;
  /** Top of the last user message relative to the top of the viewport. */
  lastUserTop: number | null;
  /** Distance from the bottom of the real content to the bottom of the viewport; 0 = resting at the end. */
  endGap: number;
};

export type ChatListHandle = {
  metrics(): ListMetrics;
  scrollToOffset(offset: number, animated: boolean): void;
  scrollToEnd(animated: boolean): void;
};

export type ChatListProps = {
  messages: Message[];
  generating: boolean;
  /** Height of the composer bar, updated as it grows. */
  composerHeight: SharedValue<number>;
  /** Changes when a conversation is opened (remount = rule 4). */
  conversationKey: string;
};

/** Distance from the top of the list to a pinned user message (rule 1). */
export const PIN_OFFSET = 8;
