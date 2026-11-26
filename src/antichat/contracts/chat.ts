/**
 * ChatPort: one conversation's thread and the generation running in it.
 * M2 builds the chat UI against this; `adapters/chat.ts` implements it on top
 * of upstream's `useChatSession` and the M7 request seam.
 */
import type {AttachmentRef, Observable, PortError, Unsubscribe} from './common';

export type MessageRole = 'user' | 'assistant';

export type MessageStatus =
  /** Sent, nothing back yet (model loading, prompt being read). */
  | 'pending'
  | 'streaming'
  | 'complete'
  /** The user pressed stop; the partial text is kept. */
  | 'stopped'
  | 'error';

/** What the status row says while an answer is on its way. */
export type GenerationPhase = 'thinking' | 'searching' | 'working' | 'writing';

/** Thumbs up / down on an answer. Kept on the phone, never sent anywhere. */
export type MessageFeedback = 'up' | 'down';

export interface ReasoningView {
  text: string;
  /** Set when thinking has finished: "Thought for 5s". */
  durationMs?: number;
}

export interface ToolCallView {
  id: string;
  /** Tool id as registered with `ToolsPort`. */
  toolId: string;
  status: 'running' | 'done' | 'failed';
  /** One line for the status row ("Searching for …"). */
  summary?: string;
}

export interface CitationView {
  id: string;
  title: string;
  url: string;
  /** Short site name for the pill. */
  source?: string;
}

export interface ChatMessageView {
  id: string;
  conversationId: string;
  role: MessageRole;
  /** Markdown for assistant messages, plain text for user messages. */
  text: string;
  status: MessageStatus;
  createdAt: number;
  attachments?: AttachmentRef[];
  reasoning?: ReasoningView;
  toolCalls?: ToolCallView[];
  citations?: CitationView[];
  /** Why the message is in `error`. */
  error?: PortError;
  /** Model that wrote the answer. */
  modelId?: string;
  /**
   * Position among sibling versions after an edit or regenerate
   * ("2 / 3"). Absent when there is only one.
   */
  version?: {index: number; count: number};
  /** The user's rating of an answer. */
  feedback?: MessageFeedback;
}

/** Fine-grained events, so a streaming row can update without diffing. */
export type ChatEvent =
  | {type: 'message_added'; message: ChatMessageView}
  | {type: 'phase'; messageId: string; phase: GenerationPhase; label?: string}
  | {type: 'text_delta'; messageId: string; delta: string}
  | {type: 'reasoning_delta'; messageId: string; delta: string}
  | {type: 'message_updated'; message: ChatMessageView}
  | {type: 'message_removed'; messageId: string}
  | {
      type: 'finished';
      messageId: string;
      status: Extract<MessageStatus, 'complete' | 'stopped' | 'error'>;
    };

/**
 * Per-message choices from the composer. The names match `SessionInfo` of the
 * request seam (`engine/prompt/types.ts`) where they overlap.
 */
export interface SendOptions {
  attachments?: AttachmentRef[];
  /** Tools switched on for this message (ids from `ToolsPort`). */
  toolIds?: string[];
  /** "Think longer" for this message. */
  thinking?: boolean;
  /** Use another installed model for this one message (long-press send). */
  modelId?: string;
  /** The reply will be spoken (voice mode). */
  spoken?: boolean;
}

export interface SendInput extends SendOptions {
  text: string;
}

export interface SendResult {
  /** A new id when the message started a conversation. */
  conversationId: string;
  userMessageId: string;
  assistantMessageId: string;
}

/** A starter prompt on the empty chat. Shape of `engine/prompt/starters.ts`. */
export interface Starter {
  id: string;
  category: 'write' | 'learn' | 'plan' | 'code' | 'think' | 'fun';
  /** Chip text; the locale file may translate it by `id`. */
  label: string;
  /** What lands in the composer. */
  prompt: string;
}

export interface ChatPort extends Observable {
  /** The active path of a conversation, oldest first. */
  messages(conversationId: string): readonly ChatMessageView[];
  /** The phase of the running answer, or null when nothing is generating. */
  phase(conversationId: string): GenerationPhase | null;
  isGenerating(conversationId: string): boolean;

  /** Token-level events for one conversation. */
  listen(
    conversationId: string,
    listener: (event: ChatEvent) => void,
  ): Unsubscribe;

  /** `conversationId` null starts a new conversation. */
  send(conversationId: string | null, input: SendInput): Promise<SendResult>;
  /** Stop the running answer and keep what was written. */
  stop(conversationId: string): void;
  /** Replace an answer with a new version. */
  regenerate(
    conversationId: string,
    assistantMessageId: string,
    options?: SendOptions,
  ): Promise<SendResult>;
  /** Replace a user message and answer it again. */
  edit(
    conversationId: string,
    userMessageId: string,
    input: SendInput,
  ): Promise<SendResult>;
  /** Show another version of a message (and the thread below it). */
  switchVersion(
    conversationId: string,
    messageId: string,
    index: number,
  ): Promise<void>;

  /**
   * Suggested next messages for the newest answer of a conversation. Empty
   * while an answer is being written, when the model is too small to write
   * them, and once the user has sent something else.
   */
  followUps(conversationId: string): readonly string[];
  /** Rate an answer, or clear the rating with `null`. */
  setFeedback(
    conversationId: string,
    messageId: string,
    feedback: MessageFeedback | null,
  ): Promise<void>;

  /** Starters for the empty chat; a few, already rotated. */
  starters(count?: number): readonly Starter[];
}
