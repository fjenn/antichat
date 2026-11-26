/**
 * The chat the voice session talks to. The adapter over the normal send
 * path implements it, so a spoken turn lands in the thread like a typed one
 * (with `spoken: true`, which adds the voice prompt addendum of
 * `engine/skills/data/voice-mode.json`).
 */

export interface VoiceSendOptions {
  /** Null starts a new chat; the result carries its id. */
  conversationId: string | null;
  /** Always true here; kept explicit because it selects the prompt addendum. */
  spoken: true;
  /** Language the user spoke (BCP-47 or Whisper code), when known. */
  language?: string;
}

export interface VoiceReplyCallbacks {
  /** Visible answer text as it is generated (no reasoning). */
  onDelta(delta: string): void;
  /** The rows exist: ids of the user turn and of the answer. */
  onMessages?(ids: {
    conversationId: string;
    userMessageId: string;
    assistantMessageId: string;
  }): void;
}

export interface VoiceReplyResult {
  status: 'complete' | 'stopped' | 'error';
  conversationId: string | null;
  assistantMessageId?: string;
  detail?: string;
}

/**
 * A reply started on a provisional transcript. Nothing is written to the
 * thread and nothing is shown until `commit`; `cancel` drops it silently.
 */
export interface SpeculativeReply {
  /** The transcript it was started with. */
  readonly text: string;
  /** Makes it the real turn: buffered deltas are replayed, then live ones. */
  commit(callbacks: VoiceReplyCallbacks): Promise<VoiceReplyResult>;
  cancel(): void;
}

export interface VoiceChatPort {
  send(
    text: string,
    options: VoiceSendOptions,
    callbacks: VoiceReplyCallbacks,
  ): Promise<VoiceReplyResult>;
  /** Stops the running reply, as the stop button does; what was written stays. */
  stop(): void;
  /** Optional: generation ahead of the final transcript. */
  speculate?(text: string, options: VoiceSendOptions): SpeculativeReply;
}
