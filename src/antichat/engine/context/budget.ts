/**
 * Token budgets for a context window (H9).
 *
 * Shape (after Off Grid `contextCompaction.ts` and AI Edge Gallery's
 * compactors): a share is reserved for the reply, the summary gets about 12%,
 * and the rest holds the system prompt and the newest turns. Fitting is
 * stepwise on purpose: when the prompt passes `triggerTokens` the history is
 * cut down to `targetTokens` in one go, then left alone for many turns. A
 * window that slid a little on every turn would change the prefix every time
 * and throw away the KV cache.
 */

export interface ContextBudget {
  nCtx: number;
  /** Tokens kept free for the reply. */
  replyReserve: number;
  /** Hard limit for the prompt. The prompt is never larger than this. */
  promptLimit: number;
  /** Compaction starts when the prompt is larger than this. */
  triggerTokens: number;
  /** Idle (after-reply) compaction starts here, so the next send is instant. */
  softTriggerTokens: number;
  /** Prompt size compaction aims for. */
  targetTokens: number;
  /** Cap for the rolling summary. */
  summaryTokens: number;
  /** Cap for one tool result inserted into the context. */
  toolResultTokens: number;
  /** Cap for one pasted/attached text in a single message. */
  attachmentTokens: number;
}

const clamp = (value: number, low: number, high: number): number =>
  Math.max(low, Math.min(high, value));

/** Budget for any window; 4k/8k/16k/32k are the planned device classes. */
export function budgetFor(nCtx: number): ContextBudget {
  const window = Math.max(1024, Math.floor(nCtx));
  const replyReserve = clamp(Math.round(window * 0.25), 384, 4096);
  // Template rounding and tokens the counter cannot see (BOS, role markers).
  const safety = Math.max(32, Math.round(window * 0.01));
  const promptLimit = window - replyReserve - safety;
  const triggerTokens = promptLimit;
  return {
    nCtx: window,
    replyReserve,
    promptLimit,
    triggerTokens,
    softTriggerTokens: Math.min(
      Math.floor(window * 0.7),
      Math.round(triggerTokens * 0.9),
    ),
    targetTokens: Math.round(window * 0.5),
    summaryTokens: clamp(Math.round(window * 0.12), 160, 1200),
    toolResultTokens: clamp(Math.round(window * 0.12), 300, 2000),
    attachmentTokens: Math.round(promptLimit * 0.5),
  };
}
