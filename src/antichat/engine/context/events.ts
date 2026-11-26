/**
 * What the UI may want to know about context management: a summary is being
 * written (show "Compacting…"), how full the window is, and when to offer
 * "Continue in a new chat".
 */

export interface ContextUsage {
  sessionId?: string;
  promptTokens: number;
  nCtx: number;
  /** The history was cut on this request. */
  compacted: boolean;
  /** A summary was (re)written on this request. */
  summarized: boolean;
  /** The chat has been compacted so often that a fresh chat would be better. */
  offerNewChat: boolean;
  /** Token counts came from the model's tokeniser. */
  exact: boolean;
}

export type ContextEvent =
  | {type: 'compacting'; sessionId?: string; active: boolean}
  | {type: 'usage'; usage: ContextUsage};

type Listener = (event: ContextEvent) => void;

const listeners = new Set<Listener>();

export function subscribeContextEvents(listener: Listener): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function emitContextEvent(event: ContextEvent): void {
  listeners.forEach(listener => {
    try {
      listener(event);
    } catch {
      // A broken listener must not break a send.
    }
  });
}
