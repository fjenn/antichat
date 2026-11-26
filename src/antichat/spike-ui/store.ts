/**
 * Minimal chat state for the spike. The message array changes only when a
 * message is added or a stream ends; tokens never touch React state. They go
 * through the TokenBatcher into the row's native markdown stream.
 */
import {useSyncExternalStore} from 'react';
import {
  createMarkdownStream,
  type MarkdownStream,
} from 'react-native-enriched-markdown';

import {StreamingHaptics} from './haptics';
import {SCRIPTED_ANSWER, SHORT_ANSWER} from './script';
import {startRun, type SourceKind, type TokenRun} from './sources';
import {TokenBatcher, type BatcherStats} from './TokenBatcher';

export type Message = {
  id: string;
  role: 'user' | 'assistant';
  /** Final text (user messages, finished or seeded answers). */
  text: string;
  /** Present while and after an answer streamed in this session. */
  stream?: MarkdownStream;
  streaming?: boolean;
};

export type RunSummary = {
  source: SourceKind;
  tokens: number;
  seconds: number;
  tokensPerSecond: number;
  stopped: boolean;
  batcher: BatcherStats;
  hapticTicks: number;
  error?: string;
};

type State = {messages: Message[]; generating: boolean};

let state: State = {messages: [], generating: false};
const listeners = new Set<() => void>();
let nextId = 1;
let run: TokenRun | undefined;

export const haptics = new StreamingHaptics();

const set = (next: Partial<State>) => {
  state = {...state, ...next};
  listeners.forEach(l => l());
};

export const chat = {
  get: () => state,
  subscribe: (l: () => void) => {
    listeners.add(l);
    return () => listeners.delete(l);
  },

  reset(): void {
    run?.stop();
    state.messages.forEach(m => m.stream?.dispose());
    set({messages: [], generating: false});
  },

  /** An old conversation: `turns` finished question/answer pairs. */
  seed(turns: number, long = true): void {
    chat.reset();
    const messages: Message[] = [];
    for (let i = 0; i < turns; i++) {
      messages.push({
        id: `m${nextId++}`,
        role: 'user',
        text: `Question ${i + 1}: explain binary search again, please.`,
      });
      messages.push({
        id: `m${nextId++}`,
        role: 'assistant',
        text: long ? SCRIPTED_ANSWER : SHORT_ANSWER,
      });
    }
    set({messages});
  },

  /**
   * Adds the user message and an empty streaming answer, then feeds tokens
   * from `source` into the answer's markdown stream, one flush per frame.
   */
  send(
    text: string,
    source: SourceKind,
    scriptedText?: string,
  ): Promise<RunSummary> {
    const stream = createMarkdownStream();
    const user: Message = {id: `m${nextId++}`, role: 'user', text};
    const answer: Message = {
      id: `m${nextId++}`,
      role: 'assistant',
      text: '',
      stream,
      streaming: true,
    };
    set({messages: [...state.messages, user, answer], generating: true});

    const ticksBefore = haptics.ticks;
    const batcher = new TokenBatcher(chunk => {
      stream.append(chunk);
      haptics.tick();
    });
    const finish = (
      r: {tokens: number; seconds: number; stopped: boolean},
      error?: string,
    ): RunSummary => {
      batcher.end();
      stream.end();
      run = undefined;
      const final = error ? `${stream.getText()}\n\n> ${error}` : undefined;
      if (final) {
        stream.reset(final);
        stream.end();
      }
      set({
        generating: false,
        messages: state.messages.map(m =>
          m.id === answer.id
            ? {...m, text: stream.getText(), streaming: false}
            : m,
        ),
      });
      return {
        source,
        tokens: r.tokens,
        seconds: r.seconds,
        tokensPerSecond: r.seconds > 0 ? r.tokens / r.seconds : 0,
        stopped: r.stopped,
        batcher: {...batcher.stats},
        hapticTicks: haptics.ticks - ticksBefore,
        error,
      };
    };
    run = startRun(source, text, t => batcher.push(t), scriptedText);
    return run.done.then(
      r => finish(r),
      e =>
        finish(
          {tokens: batcher.stats.tokens, seconds: 0, stopped: true},
          String(e?.message ?? e),
        ),
    );
  },

  stop(): void {
    run?.stop();
  },
};

export const useChat = (): State =>
  useSyncExternalStore(chat.subscribe, chat.get, chat.get);
