/**
 * What the chat screen itself remembers: the answer style, the message being
 * edited, text quoted from an answer, and which sheet is open. Nothing here
 * belongs to a port; it is the state of the screen.
 */
import AsyncStorage from '@react-native-async-storage/async-storage';
import {makeAutoObservable, runInAction} from 'mobx';
import {Platform, Settings} from 'react-native';

import type {ChatMessageView} from '../../contracts';

export type Effort = 'fast' | 'think';

const EFFORT_KEY = 'antichat.chat.effort';

export interface EditTarget {
  conversationId: string;
  messageId: string;
  text: string;
}

export class ChatUi {
  /** "Think" asks the model to reason first; off by default. */
  effort: Effort = 'fast';
  /** The next chat that is started will be an offline chat. */
  offlineNext = false;
  editing: EditTarget | null = null;
  /** Text selected in an answer that the next message refers to. */
  quote: string | null = null;
  /** The message whose thinking is shown in the sheet. */
  reasoningFor: string | null = null;
  /** The message opened for text selection. */
  selecting: ChatMessageView | null = null;

  constructor() {
    makeAutoObservable(this, {}, {autoBind: true});
  }

  async load(): Promise<void> {
    // UI tests on iOS start with a known style: `-antichatEffort fast`.
    if (Platform.OS === 'ios') {
      try {
        const asked = Settings.get('antichatEffort');
        if (asked === 'think' || asked === 'fast') {
          this.setEffort(asked);
          return;
        }
      } catch {
        // No settings module.
      }
    }
    try {
      const stored = await AsyncStorage.getItem(EFFORT_KEY);
      if (stored === 'think' || stored === 'fast') {
        runInAction(() => {
          this.effort = stored;
        });
      }
    } catch {
      // Unreadable: the default stands.
    }
  }

  setEffort(effort: Effort): void {
    this.effort = effort;
    AsyncStorage.setItem(EFFORT_KEY, effort).catch(() => {});
  }

  setOfflineNext(on: boolean): void {
    this.offlineNext = on;
  }

  startEdit(target: EditTarget): void {
    this.editing = target;
    this.quote = null;
  }

  cancelEdit(): void {
    this.editing = null;
  }

  setQuote(text: string | null): void {
    const trimmed = text?.trim();
    this.quote = trimmed ? trimmed : null;
  }

  showReasoning(messageId: string | null): void {
    this.reasoningFor = messageId;
  }

  selectText(message: ChatMessageView | null): void {
    this.selecting = message;
  }

  /** A chat was opened or left: nothing of the old one carries over. */
  resetForConversation(): void {
    this.editing = null;
    this.quote = null;
    this.reasoningFor = null;
    this.selecting = null;
  }
}

export const chatUi = new ChatUi();
