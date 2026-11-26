import {createContext, useContext} from 'react';

import type {ChatMessageView, MessageFeedback} from '../../../contracts';

/** Everything a message row can ask the screen to do. One stable object. */
export interface ThreadActions {
  /** `quiet`: the caller shows its own confirmation. */
  copy(message: ChatMessageView, quiet?: boolean): void;
  share(message: ChatMessageView): void;
  readAloud(message: ChatMessageView): void;
  setFeedback(message: ChatMessageView, feedback: MessageFeedback | null): void;
  regenerate(message: ChatMessageView): void;
  retry(message: ChatMessageView): void;
  edit(message: ChatMessageView): void;
  branch(message: ChatMessageView): void;
  selectText(message: ChatMessageView): void;
  switchVersion(message: ChatMessageView, index: number): void;
  openReasoning(message: ChatMessageView): void;
  followUp(text: string): void;
}

const noop = () => {};

export const NO_ACTIONS: ThreadActions = {
  copy: noop,
  share: noop,
  readAloud: noop,
  setFeedback: noop,
  regenerate: noop,
  retry: noop,
  edit: noop,
  branch: noop,
  selectText: noop,
  switchVersion: noop,
  openReasoning: noop,
  followUp: noop,
};

export const ThreadActionsContext = createContext<ThreadActions>(NO_ACTIONS);

export const useThreadActions = (): ThreadActions =>
  useContext(ThreadActionsContext);
