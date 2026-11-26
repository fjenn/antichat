/**
 * The thread of one conversation, as the list draws it.
 *
 * It turns a `ChatPort` into rows whose identity changes only when something
 * the row draws has changed. Tokens never reach React: they go through a
 * `TokenBatcher` into the native markdown stream of the answer that is being
 * written (docs/antichat/M0-DECISION.md, "Token-batching design").
 */
import {
  createMarkdownStream,
  type MarkdownStream,
} from 'react-native-enriched-markdown';

import type {
  ChatEvent,
  ChatMessageView,
  ChatPort,
  GenerationPhase,
} from '../../../contracts';
import {haptics} from '../../primitives';
import {TokenBatcher, type BatcherStats} from './TokenBatcher';

export interface ThreadRow {
  key: string;
  message: ChatMessageView;
  /**
   * Carries the text of an answer written in this session. Kept after the
   * answer is complete so the view does not swap its content source.
   */
  stream?: MarkdownStream;
  /** This answer is being written right now. */
  live: boolean;
  phase: GenerationPhase | null;
  phaseLabel?: string;
  /** Newest message of the thread: it shows the follow-ups. */
  last: boolean;
  /** Newest answer of the thread: only it can be regenerated in place. */
  lastAnswer: boolean;
  /** An answer is being written somewhere in this thread. */
  busy: boolean;
  /** Suggested next messages; only the newest answer carries any. */
  followUps: readonly string[];
}

export interface ThreadSnapshot {
  rows: readonly ThreadRow[];
  generating: boolean;
  /** Counts the answers started while this thread was open. */
  turn: number;
  /** The question of the newest turn: the row the list pins to the top. */
  turnAnchorKey: string | null;
  followUps: readonly string[];
}

interface LiveAnswer {
  messageId: string;
  stream: MarkdownStream;
  batcher: TokenBatcher;
  /** Everything handed to the batcher so far. */
  text: string;
}

const NO_ROWS: readonly ThreadRow[] = Object.freeze([]);
const NO_FOLLOW_UPS: readonly string[] = Object.freeze([]);

const sameItems = (a: readonly string[], b: readonly string[]): boolean =>
  a === b || (a.length === b.length && a.every((item, i) => item === b[i]));

const isOpen = (message: ChatMessageView): boolean =>
  message.role === 'assistant' &&
  (message.status === 'pending' || message.status === 'streaming');

/** What a row draws, as one comparable string. Text is left out while live. */
function signature(
  message: ChatMessageView,
  row: Pick<
    ThreadRow,
    | 'live'
    | 'phase'
    | 'phaseLabel'
    | 'last'
    | 'lastAnswer'
    | 'busy'
    | 'followUps'
  > & {
    streamed: boolean;
  },
): string {
  return [
    message.status,
    message.version ? `${message.version.index}/${message.version.count}` : '',
    message.feedback ?? '',
    message.error?.code ?? '',
    message.reasoning ? (message.reasoning.durationMs ?? 'open') : '',
    message.attachments?.length ?? 0,
    row.live ? 1 : 0,
    row.phase ?? '',
    row.phaseLabel ?? '',
    row.last ? 1 : 0,
    row.lastAnswer ? 1 : 0,
    row.streamed ? 1 : 0,
    row.busy ? 1 : 0,
    row.followUps.join('\u0000'),
  ].join('|');
}

export class ThreadController {
  private snapshot: ThreadSnapshot;
  private readonly listeners = new Set<() => void>();
  private readonly reasoningListeners = new Set<() => void>();
  private readonly offs: Array<() => void> = [];
  private readonly cache = new Map<
    string,
    {row: ThreadRow; signature: string; text: string}
  >();
  /** Streams of answers written in this session, live or finished. */
  private readonly streams = new Map<string, MarkdownStream>();
  private readonly reasoning = new Map<string, string>();
  private live: LiveAnswer | null = null;
  private phase: GenerationPhase | null = null;
  private phaseLabel: string | undefined;
  private turn = 0;
  private turnAnchorKey: string | null = null;
  private disposed = false;
  /** Batching of the last finished answer, for the frame measurements. */
  lastRun: BatcherStats | null = null;

  constructor(
    private readonly chat: ChatPort,
    readonly conversationId: string,
  ) {
    this.snapshot = {
      rows: NO_ROWS,
      generating: false,
      turn: 0,
      turnAnchorKey: null,
      followUps: NO_FOLLOW_UPS,
    };
    this.rebuild();
  }

  /** Start following the port. Safe to call again after `dispose()`. */
  attach(): void {
    if (this.offs.length > 0) {
      return;
    }
    this.disposed = false;
    this.offs.push(this.chat.listen(this.conversationId, this.onEvent));
    // Ports also announce changes that have no event (a version count that
    // arrives late, follow-ups). Cheap to check, and never per token here.
    this.offs.push(this.chat.subscribe(this.onPortChange));
    this.adoptOpenAnswer();
    this.rebuild();
  }

  getSnapshot = (): ThreadSnapshot => this.snapshot;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };

  /** The thinking text of a message, including what is still arriving. */
  reasoningOf(messageId: string): string {
    return (
      this.reasoning.get(messageId) ??
      this.chat
        .messages(this.conversationId)
        .find(message => message.id === messageId)?.reasoning?.text ??
      ''
    );
  }

  subscribeReasoning = (listener: () => void): (() => void) => {
    this.reasoningListeners.add(listener);
    return () => {
      this.reasoningListeners.delete(listener);
    };
  };

  dispose(): void {
    this.disposed = true;
    this.offs.splice(0).forEach(off => off());
    this.live?.batcher.end();
    this.live = null;
    this.streams.forEach(stream => stream.dispose());
    this.streams.clear();
    this.cache.clear();
  }

  private onEvent = (event: ChatEvent): void => {
    if (this.disposed) {
      return;
    }
    switch (event.type) {
      case 'text_delta':
        if (event.delta) {
          this.liveFor(event.messageId)?.batcher.push(event.delta);
          if (this.live?.messageId === event.messageId) {
            this.live.text += event.delta;
          }
        }
        return;
      case 'reasoning_delta':
        this.reasoning.set(
          event.messageId,
          (this.reasoning.get(event.messageId) ?? '') + event.delta,
        );
        this.reasoningListeners.forEach(listener => listener());
        return;
      case 'phase':
        this.phase = event.phase;
        this.phaseLabel = event.label;
        this.rebuild();
        return;
      case 'message_added':
        if (isOpen(event.message)) {
          this.begin(event.message);
        }
        this.rebuild();
        return;
      case 'message_updated':
        this.reconcileLive(event.message);
        this.rebuild();
        return;
      case 'message_removed':
        this.drop(event.messageId);
        this.rebuild();
        return;
      case 'finished':
        this.finish(event.messageId);
        this.rebuild();
        return;
    }
  };

  private onPortChange = (): void => {
    if (this.disposed) {
      return;
    }
    const messages = this.chat.messages(this.conversationId);
    const rows = this.snapshot.rows;
    const generating = this.chat.isGenerating(this.conversationId);
    let changed =
      messages.length !== rows.length ||
      generating !== this.snapshot.generating ||
      (!generating &&
        !sameItems(
          this.chat.followUps(this.conversationId),
          this.snapshot.followUps,
        ));
    for (let i = 0; !changed && i < messages.length; i++) {
      const message = messages[i];
      const row = rows[i];
      changed =
        row.message !== message &&
        (row.key !== message.id ||
          row.message.status !== message.status ||
          row.message.version?.count !== message.version?.count ||
          row.message.version?.index !== message.version?.index ||
          row.message.feedback !== message.feedback ||
          (!row.live && row.message.text !== message.text));
    }
    if (changed) {
      this.adoptOpenAnswer();
      this.rebuild();
    }
  };

  /** An answer that was already running when the thread was opened. */
  private adoptOpenAnswer(): void {
    if (this.live) {
      return;
    }
    const messages = this.chat.messages(this.conversationId);
    const open = messages[messages.length - 1];
    if (open && isOpen(open) && this.chat.isGenerating(this.conversationId)) {
      this.begin(open, false);
    }
  }

  private begin(message: ChatMessageView, countTurn = true): void {
    if (this.live?.messageId === message.id) {
      return;
    }
    this.live?.batcher.end();
    const stream = createMarkdownStream();
    const live: LiveAnswer = {
      messageId: message.id,
      stream,
      text: '',
      batcher: new TokenBatcher(chunk => {
        stream.append(chunk);
        haptics.streamTick();
      }),
    };
    if (message.text) {
      live.text = message.text;
      stream.append(message.text);
    }
    this.live = live;
    this.streams.set(message.id, stream);
    this.phase = this.chat.phase(this.conversationId);
    this.phaseLabel = undefined;
    if (countTurn) {
      const messages = this.chat.messages(this.conversationId);
      let anchor: string | null = null;
      for (let i = messages.length - 1; i >= 0; i--) {
        if (messages[i].role === 'user') {
          anchor = messages[i].id;
          break;
        }
      }
      this.turn += 1;
      this.turnAnchorKey = anchor;
    }
  }

  private liveFor(messageId: string): LiveAnswer | null {
    if (this.live?.messageId === messageId) {
      return this.live;
    }
    const message = this.chat
      .messages(this.conversationId)
      .find(candidate => candidate.id === messageId);
    if (message && isOpen(message)) {
      // The delta arrived before the port announced the message.
      this.begin({...message, text: ''});
      this.rebuild();
      return this.live;
    }
    return null;
  }

  /** The port replaced the text of the running answer (hygiene rewrote it). */
  private reconcileLive(message: ChatMessageView): void {
    const live = this.live;
    if (!live || live.messageId !== message.id || !isOpen(message)) {
      return;
    }
    if (message.text === live.text) {
      return;
    }
    if (message.text.startsWith(live.text)) {
      live.batcher.push(message.text.slice(live.text.length));
    } else {
      live.batcher.end();
      live.stream.reset(message.text);
      live.batcher = new TokenBatcher(chunk => {
        live.stream.append(chunk);
        haptics.streamTick();
      });
    }
    live.text = message.text;
  }

  private finish(messageId: string): void {
    const live = this.live;
    if (!live || live.messageId !== messageId) {
      return;
    }
    live.batcher.end();
    live.stream.end();
    this.lastRun = {...live.batcher.stats};
    this.live = null;
    this.phase = null;
    this.phaseLabel = undefined;
    const final = this.chat
      .messages(this.conversationId)
      .find(message => message.id === messageId);
    // The stored answer can differ from what streamed (a cut loop, a late
    // clean-up). Then the row shows the stored text instead of the stream.
    if (final && final.text.trim() !== live.text.trim()) {
      live.stream.dispose();
      this.streams.delete(messageId);
    }
  }

  private drop(messageId: string): void {
    if (this.live?.messageId === messageId) {
      this.live.batcher.end();
      this.live = null;
      this.phase = null;
    }
    this.streams.get(messageId)?.dispose();
    this.streams.delete(messageId);
    this.reasoning.delete(messageId);
  }

  private rebuild(): void {
    const messages = this.chat.messages(this.conversationId);
    const generating = this.chat.isGenerating(this.conversationId);
    if (this.live) {
      const liveId = this.live.messageId;
      const current = messages.find(message => message.id === liveId);
      if (!current || !isOpen(current)) {
        // The run ended without a `finished` event reaching us.
        this.finish(liveId);
      }
    }
    let lastAnswerIndex = -1;
    for (let i = messages.length - 1; i >= 0; i--) {
      if (messages[i].role === 'assistant') {
        lastAnswerIndex = i;
        break;
      }
    }
    const offered = generating
      ? NO_FOLLOW_UPS
      : this.chat.followUps(this.conversationId);
    const followUps = sameItems(offered, this.snapshot.followUps)
      ? this.snapshot.followUps
      : offered;
    const seen = new Set<string>();
    let same = messages.length === this.snapshot.rows.length;
    const rows = messages.map((message, index) => {
      seen.add(message.id);
      const live = this.live?.messageId === message.id;
      const stream = this.streams.get(message.id);
      const partial = {
        live,
        phase: live ? this.phase : null,
        phaseLabel: live ? this.phaseLabel : undefined,
        last: index === messages.length - 1,
        lastAnswer: index === lastAnswerIndex,
        busy: generating,
        followUps:
          index === messages.length - 1 && message.role === 'assistant'
            ? followUps
            : NO_FOLLOW_UPS,
      };
      const sig = signature(message, {...partial, streamed: !!stream});
      const cached = this.cache.get(message.id);
      if (
        cached &&
        cached.signature === sig &&
        (live || cached.text === message.text)
      ) {
        if (this.snapshot.rows[index] !== cached.row) {
          same = false;
        }
        return cached.row;
      }
      same = false;
      const row: ThreadRow = {key: message.id, message, stream, ...partial};
      this.cache.set(message.id, {row, signature: sig, text: message.text});
      return row;
    });
    for (const key of [...this.cache.keys()]) {
      if (!seen.has(key)) {
        this.cache.delete(key);
        if (this.live?.messageId !== key) {
          this.streams.get(key)?.dispose();
          this.streams.delete(key);
        }
      }
    }
    if (
      same &&
      generating === this.snapshot.generating &&
      this.turn === this.snapshot.turn &&
      followUps === this.snapshot.followUps
    ) {
      return;
    }
    this.snapshot = {
      rows: same ? this.snapshot.rows : rows,
      generating,
      turn: this.turn,
      turnAnchorKey: this.turnAnchorKey,
      followUps,
    };
    this.listeners.forEach(listener => listener());
  }
}
