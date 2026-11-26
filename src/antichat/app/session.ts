/**
 * What the shell is showing: which chat is open. `null` is the new, empty
 * chat the app launches into.
 */
import {makeAutoObservable} from 'mobx';

/** A message the thread should scroll to and mark (a search hit). */
export interface ThreadFocus {
  conversationId: string;
  messageId?: string;
  /** The search words, so the thread can highlight them. */
  query?: string;
}

export class ShellSession {
  activeConversationId: string | null = null;
  /** ANTICHAT M4: the new chat is a temporary one (nothing is kept). */
  temporary = false;
  /** ANTICHAT M4: set when a chat is opened from a search hit. */
  focus: ThreadFocus | null = null;

  constructor() {
    makeAutoObservable(this);
  }

  open(
    conversationId: string,
    focus?: Omit<ThreadFocus, 'conversationId'>,
  ): void {
    this.activeConversationId = conversationId;
    this.temporary = false;
    this.focus = focus ? {conversationId, ...focus} : null;
  }

  /** The temporary new chat got its first message and with it an id. */
  openTemporary(conversationId: string): void {
    this.activeConversationId = conversationId;
    this.temporary = true;
    this.focus = null;
  }

  newChat(options: {temporary?: boolean} = {}): void {
    this.activeConversationId = null;
    this.temporary = options.temporary === true;
    this.focus = null;
  }

  setTemporary(temporary: boolean): void {
    this.temporary = temporary;
  }

  clearFocus(): void {
    this.focus = null;
  }
}

export const shellSession = new ShellSession();
