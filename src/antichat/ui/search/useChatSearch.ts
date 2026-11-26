import {useEffect, useRef, useState} from 'react';

import type {ConversationPort, SearchHit} from '../../contracts';

export interface ChatSearchState {
  /** The query the hits belong to ('' before the first answer). */
  answeredQuery: string;
  hits: readonly SearchHit[];
  /** A query is typed and its answer has not arrived yet. */
  pending: boolean;
  /** Milliseconds the last search took. */
  tookMs: number;
}

const EMPTY: ChatSearchState = {
  answeredQuery: '',
  hits: [],
  pending: false,
  tookMs: 0,
};

/** Wait this long after a keystroke; a search is a few milliseconds. */
export const SEARCH_DEBOUNCE_MS = 60;

/**
 * Searches as the user types. Results of an older query never replace those
 * of a newer one, and the previous results stay on screen until the next
 * ones arrive, so the list does not flash empty between keystrokes.
 */
export function useChatSearch(
  port: ConversationPort,
  query: string,
  hidden?: ReadonlySet<string>,
): ChatSearchState {
  const [state, setState] = useState<ChatSearchState>(EMPTY);
  const sequence = useRef(0);
  const trimmed = query.trim();

  useEffect(() => {
    const ticket = ++sequence.current;
    if (!trimmed) {
      setState(EMPTY);
      return;
    }
    setState(previous => ({...previous, pending: true}));
    const timer = setTimeout(() => {
      const started = Date.now();
      port
        .search(trimmed, {limit: 40})
        .then(hits => {
          if (ticket === sequence.current) {
            setState({
              answeredQuery: trimmed,
              hits,
              pending: false,
              tookMs: Date.now() - started,
            });
          }
        })
        .catch(() => {
          if (ticket === sequence.current) {
            setState({
              answeredQuery: trimmed,
              hits: [],
              pending: false,
              tookMs: 0,
            });
          }
        });
    }, SEARCH_DEBOUNCE_MS);
    return () => clearTimeout(timer);
  }, [port, trimmed]);

  // The store changed (a chat was deleted or renamed): ask again.
  useEffect(() => {
    if (!trimmed) {
      return;
    }
    return port.subscribe(() => {
      const ticket = ++sequence.current;
      port
        .search(trimmed, {limit: 40})
        .then(hits => {
          if (ticket === sequence.current) {
            setState(previous => ({...previous, hits, pending: false}));
          }
        })
        .catch(() => {});
    });
  }, [port, trimmed]);

  if (!hidden || hidden.size === 0) {
    return state;
  }
  return {
    ...state,
    hits: state.hits.filter(hit => !hidden.has(hit.conversation.id)),
  };
}
