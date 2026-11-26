/**
 * Chat adapter (M2): the real `ChatPort` on top of upstream's send pipeline.
 *
 * Upstream keeps doing the work: `useChatSession` runs the generation and
 * writes tokens into ChatSessionStore; the M7 engine rewrites the request at
 * the seam and names the chat afterwards; the M3 store keeps replaced
 * answers as versions. This file
 *  - maps upstream's rows to `ChatMessageView`s (cleaned text, separated
 *    thinking, typed errors) and keeps them identical while nothing changed,
 *  - turns store updates into fine-grained events (`listen`), so a streaming
 *    row can append text without anything re-rendering,
 *  - implements send / stop / regenerate / edit / switch on upstream calls.
 *
 * `UpstreamChat` reaches upstream only through `ChatUpstream`, which Jest
 * replaces with an in-memory double. `createUpstream()` is the real one;
 * `ChatSessionHost` is the component that lends it upstream's hook.
 */
import {useEffect, useRef} from 'react';
import {autorun, reaction, runInAction} from 'mobx';

import type {
  ChatEvent,
  ChatMessageView,
  ChatPort,
  GenerationPhase,
  MessageFeedback,
  MessageStatus,
  SendInput,
  SendOptions,
  SendResult,
  Starter,
} from '../contracts/chat';
import {Emitter, type PortError, type Unsubscribe} from '../contracts/common';
import {cleanModelOutput} from '../engine/prompt/hygiene';
import {setChip} from '../engine/tools/chips';
import type {AgentStep, MessageType} from '../../utils/types';

// ------------------------------------------------------------ upstream seam

/** What this adapter stores in a message's `metadata`. */
export const META = {
  /** The user pressed stop on this answer. */
  stopped: 'antichatStopped',
  /** How long the model thought before it answered, in ms. */
  thinkingMs: 'antichatThinkingMs',
  feedback: 'antichatFeedback',
  modelId: 'antichatModelId',
  /** Error code of a row this adapter wrote itself. */
  error: 'antichatError',
} as const;

export interface OutgoingMessage {
  text: string;
  imageUris?: string[];
}

export type ModelReadiness = 'ready' | 'none' | 'failed';

/**
 * Everything the adapter asks of upstream. Reads go through MobX
 * observables (the adapter calls them inside an `autorun`).
 */
export interface ChatUpstream {
  readonly userId: string;

  activeSessionId(): string | null;
  /** A chat's rows, newest first, or undefined when it is not loaded. */
  messagesOf(sessionId: string): readonly MessageType.Any[] | undefined;
  isGenerating(): boolean;
  activeModelId(): string | undefined;

  /** Makes `sessionId` the open chat; null is the new, empty chat. */
  activate(sessionId: string | null): Promise<void>;
  /** Loads a model when none is; never downloads one. */
  ensureModel(): Promise<ModelReadiness>;
  setThinking(enabled: boolean): Promise<void>;
  /**
   * Upstream's `handleSendPress`. Resolves when the whole run is over;
   * `onTurnCreated` fires as soon as the answer's row exists.
   */
  sendMessage(
    message: OutgoingMessage,
    onTurnCreated: (turnId: string) => void,
  ): Promise<unknown>;
  stop(): Promise<void>;
  /** Deletes the open chat's rows from `messageId` on (edit, regenerate). */
  removeFrom(messageId: string, includeMessage: boolean): Promise<void>;
  /** Adds a user row without starting a run. Returns its id. */
  addUserRow(message: OutgoingMessage): Promise<string>;
  /** Adds a row that explains a failure. Returns its id. */
  addErrorRow(code: PortError['code'], detail: string): Promise<string>;
  updateMetadata(
    sessionId: string,
    messageId: string,
    metadata: Record<string, unknown>,
  ): Promise<void>;
  /** What a row upstream wrote by itself means; null hides the row. */
  classifySystemRow(text: string): PortError | null;

  /** Position of each message among its versions, by message id. */
  versions(
    sessionId: string,
  ): Promise<Map<string, {index: number; count: number}>>;
  switchVersion(
    sessionId: string,
    messageId: string,
    index: number,
  ): Promise<void>;
  /** The conversation store changed (a version was parked or swapped). */
  onStoreChange(listener: () => void): Unsubscribe;
  onFollowUps(
    listener: (sessionId: string | undefined, items: string[]) => void,
  ): Unsubscribe;
  starters(count: number): readonly Starter[];
}

// ------------------------------------------------------------------ mapping

interface Run {
  sessionId: string;
  turnId: string | null;
  startedAt: number;
  stopRequested: boolean;
  /** Upstream's send promise has settled. */
  ended: boolean;
  reasoningStartedAt: number | null;
  thinkingMs: number | null;
  /** Text already handed to `listen` listeners as deltas. */
  emittedText: string;
  emittedReasoning: string;
  modelId?: string;
}

interface CachedView {
  signature: string;
  view: ChatMessageView;
}

interface SessionViews {
  views: readonly ChatMessageView[];
  byId: Map<string, CachedView>;
}

const EMPTY: readonly ChatMessageView[] = Object.freeze([]);
const NO_FOLLOW_UPS: readonly string[] = Object.freeze([]);

/** How long an interrupted run may take to wind down before we go on. */
const SETTLE_TIMEOUT_MS = 15_000;

const noop = () => {};

function stepText(steps: readonly AgentStep[] | undefined): {
  content: string;
  reasoning: string;
} {
  const content: string[] = [];
  const reasoning: string[] = [];
  for (const step of steps ?? []) {
    if (step.content) {
      content.push(step.content);
    }
    if (step.reasoningContent) {
      reasoning.push(step.reasoningContent);
    }
  }
  return {content: content.join('\n\n'), reasoning: reasoning.join('\n\n')};
}

const tail = (text: string): string => text.slice(-12);

export interface UpstreamChatOptions {
  now?: () => number;
  /** Derives the visible text of a turn; upstream's `derivedText`. */
  visibleText?: (turn: MessageType.AssistantTurn) => string;
}

export class UpstreamChat extends Emitter implements ChatPort {
  private readonly sessions = new Map<string, SessionViews>();
  private readonly versionCache = new Map<
    string,
    Map<string, {index: number; count: number}>
  >();
  private readonly eventListeners = new Map<
    string,
    Set<(event: ChatEvent) => void>
  >();
  private readonly suggestions = new Map<string, readonly string[]>();
  private readonly stoppedIds = new Set<string>();
  private readonly now: () => number;
  private readonly visibleText: (turn: MessageType.AssistantTurn) => string;
  private disposers: Unsubscribe[] = [];
  private run: Run | null = null;
  /** The upstream send that is still writing, if any. */
  private running: Promise<void> | null = null;
  /** Between "send was pressed" and "the run is over". */
  private dispatching = false;
  private loadingModelFor: string | null | undefined;
  private lastPhase: GenerationPhase | null = null;
  private lastGenerating = false;
  private watchedSession: string | null = null;
  private started = false;

  constructor(
    private readonly upstream: ChatUpstream,
    options: UpstreamChatOptions = {},
  ) {
    super();
    this.now = options.now ?? Date.now;
    this.visibleText =
      options.visibleText ?? (turn => stepText(turn.steps).content);
  }

  /** Starts following upstream. Idempotent; `dispose` undoes it. */
  start(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    this.disposers.push(
      autorun(() => this.sync()),
      this.upstream.onStoreChange(() => this.refreshVersions()),
      this.upstream.onFollowUps((sessionId, items) => {
        // Suggestions for a chat the user has left, or for an answer that
        // is already being replaced, are stale.
        if (
          !sessionId ||
          sessionId !== this.upstream.activeSessionId() ||
          this.dispatching ||
          items.length === 0
        ) {
          return;
        }
        this.suggestions.set(sessionId, Object.freeze([...items]));
        this.emit();
      }),
    );
  }

  dispose(): void {
    this.disposers.forEach(off => off());
    this.disposers = [];
    this.started = false;
  }

  // ------------------------------------------------------------- reading

  messages(conversationId: string): readonly ChatMessageView[] {
    this.start();
    if (conversationId !== this.watchedSession) {
      // Not the open chat: map on demand, nothing is listening to it.
      return this.mapSession(conversationId).views;
    }
    return this.sessions.get(conversationId)?.views ?? EMPTY;
  }

  phase(conversationId: string): GenerationPhase | null {
    if (this.loadingModelFor !== undefined) {
      return this.loadingModelFor === conversationId ||
        this.loadingModelFor === null
        ? 'working'
        : null;
    }
    if (!this.isGenerating(conversationId)) {
      return null;
    }
    const run = this.run;
    return run && run.reasoningStartedAt !== null && run.thinkingMs === null
      ? 'thinking'
      : 'writing';
  }

  isGenerating(conversationId: string): boolean {
    return (
      this.upstream.isGenerating() &&
      this.upstream.activeSessionId() === conversationId
    );
  }

  listen(
    conversationId: string,
    listener: (event: ChatEvent) => void,
  ): Unsubscribe {
    this.start();
    const set = this.eventListeners.get(conversationId) ?? new Set();
    set.add(listener);
    this.eventListeners.set(conversationId, set);
    return () => {
      set.delete(listener);
    };
  }

  followUps(conversationId: string): readonly string[] {
    return this.suggestions.get(conversationId) ?? NO_FOLLOW_UPS;
  }

  starters(count = 4): readonly Starter[] {
    return this.upstream.starters(count);
  }

  // ------------------------------------------------------------ commands

  async send(
    conversationId: string | null,
    input: SendInput,
  ): Promise<SendResult> {
    this.start();
    return this.serial(async () => {
      await this.interrupt();
      this.clearFollowUps();
      if (this.upstream.activeSessionId() !== conversationId) {
        await this.upstream.activate(conversationId);
      }
      if (input.toolIds?.includes('search')) {
        // The + sheet's Search switch: one-shot, read when the request is
        // built (a new chat has no id yet, hence the shared slot).
        setChip(conversationId ?? undefined, 'search', true);
      }
      return this.dispatch(
        {text: input.text, imageUris: imageUrisOf(input)},
        input,
      );
    });
  }

  stop(conversationId: string): void {
    if (!this.isGenerating(conversationId)) {
      return;
    }
    this.requestStop();
  }

  async regenerate(
    conversationId: string,
    assistantMessageId: string,
    options: SendOptions = {},
  ): Promise<SendResult> {
    this.start();
    return this.serial(() =>
      this.regenerateNow(conversationId, assistantMessageId, options),
    );
  }

  private async regenerateNow(
    conversationId: string,
    assistantMessageId: string,
    options: SendOptions,
  ): Promise<SendResult> {
    await this.interrupt();
    this.clearFollowUps();
    await this.open(conversationId);
    const views = this.mapSession(conversationId).views;
    const at = views.findIndex(view => view.id === assistantMessageId);
    let userAt = at;
    while (userAt >= 0 && views[userAt].role !== 'user') {
      userAt--;
    }
    const prompt = views[userAt];
    if (at < 0 || !prompt) {
      throw new Error(`No answer ${assistantMessageId} to regenerate`);
    }
    // Upstream's way: drop the question and what follows, ask it again. The
    // conversation store recognises the same question and files the new
    // answer as a version of the old one.
    await this.upstream.removeFrom(prompt.id, true);
    return this.dispatch(
      {
        text: prompt.text,
        imageUris: prompt.attachments
          ?.filter(attachment => attachment.kind === 'image')
          .map(attachment => attachment.uri),
      },
      options,
    );
  }

  async edit(
    conversationId: string,
    userMessageId: string,
    input: SendInput,
  ): Promise<SendResult> {
    this.start();
    return this.serial(() =>
      this.editNow(conversationId, userMessageId, input),
    );
  }

  private async editNow(
    conversationId: string,
    userMessageId: string,
    input: SendInput,
  ): Promise<SendResult> {
    await this.interrupt();
    this.clearFollowUps();
    await this.open(conversationId);
    const views = this.mapSession(conversationId).views;
    if (
      !views.some(view => view.id === userMessageId && view.role === 'user')
    ) {
      throw new Error(`No message ${userMessageId} to edit`);
    }
    await this.upstream.removeFrom(userMessageId, true);
    return this.dispatch(
      {text: input.text, imageUris: imageUrisOf(input)},
      input,
    );
  }

  async switchVersion(
    conversationId: string,
    messageId: string,
    index: number,
  ): Promise<void> {
    this.start();
    return this.serial(async () => {
      // The store refuses to swap a thread that is being written to.
      await this.interrupt();
      this.clearFollowUps();
      await this.open(conversationId);
      await this.upstream.switchVersion(conversationId, messageId, index);
      await this.refreshVersions();
    });
  }

  async setFeedback(
    conversationId: string,
    messageId: string,
    feedback: MessageFeedback | null,
  ): Promise<void> {
    await this.upstream.updateMetadata(conversationId, messageId, {
      [META.feedback]: feedback,
    });
    this.sync();
  }

  // ------------------------------------------------------------ internals

  private async open(conversationId: string): Promise<void> {
    if (this.upstream.activeSessionId() !== conversationId) {
      await this.upstream.activate(conversationId);
    }
  }

  private clearFollowUps(): void {
    if (this.suggestions.size > 0) {
      this.suggestions.clear();
      this.emit();
    }
  }

  private requestStop(): void {
    const run = this.run;
    // A run that has already ended by itself was not stopped by anyone.
    if (run && !run.ended) {
      run.stopRequested = true;
      if (run.turnId) {
        this.stoppedIds.add(run.turnId);
        this.sync();
      }
    }
    this.upstream.stop().catch(noop);
  }

  /** Commands run one after the other, in the order they were given. */
  private serial<T>(work: () => Promise<T>): Promise<T> {
    const next = this.queue.then(work, work);
    this.queue = next.then(noop, noop);
    return next;
  }

  private queue: Promise<void> = Promise.resolve();

  /** Stops the running answer and waits until upstream has let go of it. */
  private async interrupt(): Promise<void> {
    if (this.upstream.isGenerating() || (this.run && !this.run.ended)) {
      this.requestStop();
    }
    const running = this.running;
    if (!running) {
      return;
    }
    let timer: ReturnType<typeof setTimeout> | undefined;
    await Promise.race([
      running,
      new Promise<void>(resolve => {
        timer = setTimeout(resolve, SETTLE_TIMEOUT_MS);
      }),
    ]);
    clearTimeout(timer);
  }

  private async dispatch(
    message: OutgoingMessage,
    options: SendOptions,
  ): Promise<SendResult> {
    this.dispatching = true;
    let handedOver = false;
    try {
      this.loadingModelFor = this.upstream.activeSessionId();
      this.publishPhase();
      let readiness: ModelReadiness;
      try {
        readiness = await this.upstream.ensureModel();
      } catch {
        readiness = 'failed';
      } finally {
        this.loadingModelFor = undefined;
      }
      if (readiness !== 'ready') {
        // Keep what the user wrote and say why there is no answer.
        const userMessageId = await this.upstream.addUserRow(message);
        const errorId = await this.upstream.addErrorRow(
          'model_not_loaded',
          readiness === 'none' ? 'No model is installed' : 'Model load failed',
        );
        this.publishPhase();
        return {
          conversationId: this.upstream.activeSessionId() ?? '',
          userMessageId,
          assistantMessageId: errorId,
        };
      }
      await this.upstream.setThinking(options.thinking === true);

      const run: Run = {
        sessionId: this.upstream.activeSessionId() ?? '',
        turnId: null,
        startedAt: this.now(),
        stopRequested: false,
        ended: false,
        reasoningStartedAt: null,
        thinkingMs: null,
        emittedText: '',
        emittedReasoning: '',
        modelId: options.modelId ?? this.upstream.activeModelId(),
      };
      this.run = run;

      let announce: (turnId: string | null) => void = noop;
      const created = new Promise<string | null>(resolve => {
        announce = resolve;
      });
      const finished = this.upstream
        .sendMessage(message, turnId => {
          run.turnId = turnId;
          run.sessionId = this.upstream.activeSessionId() ?? run.sessionId;
          if (run.stopRequested) {
            this.stoppedIds.add(turnId);
          }
          announce(turnId);
        })
        .then(noop, error => {
          console.warn('[antichat] send failed', error);
        })
        .then(() => {
          run.ended = true;
        });
      this.running = finished.then(() => this.finishRun(run));
      handedOver = true;
      // No row for the answer: upstream gave up before the run (it explains
      // itself with a row of its own).
      finished.then(() => announce(null)).catch(noop);

      const turnId = await created;
      const sessionId = this.upstream.activeSessionId() ?? run.sessionId;
      const views = this.mapSession(sessionId).views;
      const lastUser = [...views].reverse().find(view => view.role === 'user');
      const lastView = views[views.length - 1];
      return {
        conversationId: sessionId,
        userMessageId: lastUser?.id ?? '',
        assistantMessageId: turnId ?? lastView?.id ?? '',
      };
    } finally {
      if (!handedOver) {
        this.dispatching = false;
        this.sync();
      }
    }
  }

  /** The run is over: record what only this adapter knows about it. */
  private async finishRun(run: Run): Promise<void> {
    try {
      const turnId = run.turnId;
      const rows = turnId ? this.upstream.messagesOf(run.sessionId) : undefined;
      if (turnId && rows?.some(row => row.id === turnId)) {
        if (run.reasoningStartedAt !== null && run.thinkingMs === null) {
          // It thought and never answered (stopped, or ran out of tokens).
          run.thinkingMs = this.now() - run.reasoningStartedAt;
        }
        const metadata: Record<string, unknown> = {};
        if (run.stopRequested) {
          metadata[META.stopped] = true;
        }
        if (run.thinkingMs !== null) {
          metadata[META.thinkingMs] = run.thinkingMs;
        }
        if (run.modelId) {
          metadata[META.modelId] = run.modelId;
        }
        if (Object.keys(metadata).length > 0) {
          await this.upstream
            .updateMetadata(run.sessionId, turnId, metadata)
            .catch(noop);
        }
      }
    } finally {
      if (this.run === run) {
        this.run = null;
      }
      this.running = null;
      this.dispatching = false;
      this.sync();
      const status = run.turnId ? this.statusOfTurn(run) : null;
      if (run.turnId && status) {
        this.dispatchEvent(run.sessionId, {
          type: 'finished',
          messageId: run.turnId,
          status,
        });
      }
      if (run.turnId) {
        this.stoppedIds.delete(run.turnId);
      }
      this.emit();
      this.refreshVersions().catch(noop);
    }
  }

  private statusOfTurn(run: Run): 'complete' | 'stopped' | 'error' | null {
    const view = this.sessions
      .get(run.sessionId)
      ?.views.find(item => item.id === run.turnId);
    if (!view) {
      // Upstream removed an answer that failed before its first token.
      return 'error';
    }
    if (view.status === 'error') {
      return 'error';
    }
    return run.stopRequested ? 'stopped' : 'complete';
  }

  private async refreshVersions(): Promise<void> {
    const sessionId = this.upstream.activeSessionId();
    if (!sessionId) {
      return;
    }
    try {
      const next = await this.upstream.versions(sessionId);
      this.versionCache.set(sessionId, next);
      this.sync();
    } catch {
      // The version switcher simply does not show until the store answers.
    }
  }

  private dispatchEvent(conversationId: string, event: ChatEvent): void {
    this.eventListeners.get(conversationId)?.forEach(listener => {
      try {
        listener(event);
      } catch (error) {
        console.warn('[antichat] chat listener threw', error);
      }
    });
  }

  private publishPhase(): void {
    const sessionId = this.upstream.activeSessionId();
    const phase = sessionId ? this.phase(sessionId) : null;
    if (phase === this.lastPhase) {
      return;
    }
    this.lastPhase = phase;
    if (sessionId && phase) {
      const turnId = this.run?.turnId;
      this.dispatchEvent(sessionId, {
        type: 'phase',
        messageId: turnId ?? '',
        phase,
        ...(this.loadingModelFor !== undefined
          ? {label: 'loading_model'}
          : null),
      });
    }
    this.emit();
  }

  /**
   * Reads the open chat from upstream and tells listeners what changed.
   * Runs inside an `autorun`, so every observable read here re-triggers it.
   */
  private sync(): void {
    const sessionId = this.upstream.activeSessionId();
    const generating = this.upstream.isGenerating();
    if (sessionId !== this.watchedSession) {
      this.watchedSession = sessionId;
      // Follow-ups belong to the chat they were written for.
      this.suggestions.clear();
      this.lastPhase = null;
      this.lastGenerating = generating;
      if (sessionId) {
        this.mapSession(sessionId);
        this.refreshVersions().catch(noop);
      }
      this.emit();
      return;
    }
    if (!sessionId) {
      return;
    }
    const before = this.sessions.get(sessionId)?.views ?? EMPTY;
    const after = this.mapSession(sessionId).views;
    let structural = generating !== this.lastGenerating;
    this.lastGenerating = generating;

    if (before !== after) {
      const previous = new Map(before.map(view => [view.id, view]));
      const current = new Set(after.map(view => view.id));
      for (const view of before) {
        if (!current.has(view.id)) {
          structural = true;
          this.dispatchEvent(sessionId, {
            type: 'message_removed',
            messageId: view.id,
          });
        }
      }
      for (const view of after) {
        const old = previous.get(view.id);
        if (!old) {
          structural = true;
          this.primeRun(view);
          this.dispatchEvent(sessionId, {type: 'message_added', message: view});
        } else if (old !== view) {
          if (this.emitChange(sessionId, old, view)) {
            structural = true;
          }
        }
      }
    }
    this.publishPhase();
    if (structural) {
      this.emit();
    }
  }

  /** A row that appears with text already in it has nothing left to stream. */
  private primeRun(view: ChatMessageView): void {
    const run = this.run;
    if (run && run.turnId === view.id) {
      run.emittedText = view.text;
      run.emittedReasoning = view.reasoning?.text ?? '';
    }
  }

  /** Returns true when the change is more than new text on a streaming row. */
  private emitChange(
    sessionId: string,
    old: ChatMessageView,
    view: ChatMessageView,
  ): boolean {
    const run = this.run;
    const streaming =
      run !== null &&
      run.turnId === view.id &&
      view.status === 'streaming' &&
      old.status === 'streaming' &&
      old.version?.index === view.version?.index &&
      old.version?.count === view.version?.count &&
      old.feedback === view.feedback;
    if (!streaming || !run) {
      if (run && run.turnId === view.id) {
        run.emittedText = view.text;
        run.emittedReasoning = view.reasoning?.text ?? '';
      }
      this.dispatchEvent(sessionId, {type: 'message_updated', message: view});
      return true;
    }
    const reasoning = view.reasoning?.text ?? '';
    const textGrew = view.text.startsWith(run.emittedText);
    const reasoningGrew = reasoning.startsWith(run.emittedReasoning);
    if (!textGrew || !reasoningGrew) {
      // The clean-up changed text that was already shown (a marker that
      // turned out to be markup, a cut repetition): replace, do not append.
      run.emittedText = view.text;
      run.emittedReasoning = reasoning;
      this.dispatchEvent(sessionId, {type: 'message_updated', message: view});
      return false;
    }
    const reasoningDelta = reasoning.slice(run.emittedReasoning.length);
    if (reasoningDelta) {
      run.emittedReasoning = reasoning;
      this.dispatchEvent(sessionId, {
        type: 'reasoning_delta',
        messageId: view.id,
        delta: reasoningDelta,
      });
    }
    const textDelta = view.text.slice(run.emittedText.length);
    if (textDelta) {
      run.emittedText = view.text;
      this.dispatchEvent(sessionId, {
        type: 'text_delta',
        messageId: view.id,
        delta: textDelta,
      });
    }
    // "Thought for Ns" appears when the answer starts: a row-level change.
    if (old.reasoning?.durationMs !== view.reasoning?.durationMs) {
      this.dispatchEvent(sessionId, {type: 'message_updated', message: view});
    }
    return false;
  }

  private mapSession(sessionId: string): SessionViews {
    const generating = this.upstream.isGenerating();
    const rows = this.upstream.messagesOf(sessionId);
    const cached = this.sessions.get(sessionId) ?? {
      views: EMPTY,
      byId: new Map<string, CachedView>(),
    };
    if (!rows) {
      return cached;
    }
    const versions = this.versionCache.get(sessionId);
    const isOpen = sessionId === this.upstream.activeSessionId();
    const byId = new Map<string, CachedView>();
    const views: ChatMessageView[] = [];
    // Upstream keeps the newest row first.
    for (let i = rows.length - 1; i >= 0; i--) {
      const row = rows[i];
      const live = generating && isOpen && i === 0;
      const signature = this.signatureOf(row, live, versions?.get(row.id));
      if (signature === null) {
        continue;
      }
      const known = cached.byId.get(row.id);
      const entry =
        known && known.signature === signature
          ? known
          : {
              signature,
              view: this.viewOf(sessionId, row, live, versions?.get(row.id)),
            };
      byId.set(row.id, entry);
      views.push(entry.view);
    }
    // A question nothing answered (the run failed before its first token,
    // or the app was closed mid-answer) gets a row that offers a retry.
    const last = views[views.length - 1];
    if (
      last &&
      last.role === 'user' &&
      isOpen &&
      !generating &&
      !this.dispatching
    ) {
      const id = `${last.id}:unanswered`;
      const known = cached.byId.get(id);
      const entry = known ?? {
        signature: 'unanswered',
        view: {
          id,
          conversationId: sessionId,
          role: 'assistant' as const,
          text: '',
          status: 'error' as const,
          createdAt: last.createdAt,
          error: {code: 'failed' as const, retryable: true},
        },
      };
      byId.set(id, entry);
      views.push(entry.view);
    }
    const same =
      views.length === cached.views.length &&
      views.every((view, index) => view === cached.views[index]);
    const result: SessionViews = {
      views: same ? cached.views : Object.freeze(views),
      byId,
    };
    this.sessions.set(sessionId, result);
    return result;
  }

  /**
   * A cheap fingerprint of everything a view is built from, read through
   * the observables so the autorun follows it. Null hides the row.
   */
  private signatureOf(
    row: MessageType.Any,
    live: boolean,
    version: {index: number; count: number} | undefined,
  ): string | null {
    const metadata = row.metadata ?? {};
    const versionKey = version ? `${version.index}/${version.count}` : '';
    if (row.type === 'assistant_turn') {
      const steps = (row as MessageType.AssistantTurn).steps ?? [];
      let key = '';
      for (const step of steps) {
        const content = step.content ?? '';
        const reasoning = step.reasoningContent ?? '';
        key += `${content.length}:${tail(content)}:${reasoning.length}:${
          step.toolCalls?.length ?? 0
        };`;
      }
      const run = this.run;
      const mine = run !== null && run.turnId === row.id;
      return [
        'a',
        key,
        live ? 1 : 0,
        metadata.interrupted ? 1 : 0,
        metadata.truncationLikely ? 1 : 0,
        metadata[META.stopped] || this.stoppedIds.has(row.id) ? 1 : 0,
        metadata[META.thinkingMs] ?? '',
        metadata[META.feedback] ?? '',
        mine ? (run.thinkingMs ?? '') : '',
        versionKey,
      ].join('|');
    }
    if (row.type !== 'text') {
      return null;
    }
    const text = (row as MessageType.Text).text ?? '';
    if (metadata.system) {
      const code = metadata[META.error];
      if (!code && this.upstream.classifySystemRow(text) === null) {
        return null;
      }
      return `s|${code ?? ''}|${text.length}:${tail(text)}`;
    }
    if (row.author?.id !== this.upstream.userId) {
      // An answer written before upstream had turns: plain text.
      return `t|${text.length}:${tail(text)}|${metadata[META.feedback] ?? ''}|${versionKey}`;
    }
    const images = (row as MessageType.Text).imageUris ?? [];
    return `u|${text.length}:${tail(text)}|${images.join(',')}|${versionKey}`;
  }

  private viewOf(
    sessionId: string,
    row: MessageType.Any,
    live: boolean,
    version: {index: number; count: number} | undefined,
  ): ChatMessageView {
    const metadata = row.metadata ?? {};
    const base = {
      id: row.id,
      conversationId: sessionId,
      createdAt: row.createdAt ?? 0,
    };
    const versioned = version && version.count > 1 ? {version} : null;
    const feedback =
      metadata[META.feedback] === 'up' || metadata[META.feedback] === 'down'
        ? {feedback: metadata[META.feedback] as MessageFeedback}
        : null;

    if (row.type === 'assistant_turn') {
      return {
        ...base,
        role: 'assistant',
        ...this.turnFields(row as MessageType.AssistantTurn, live),
        ...versioned,
        ...feedback,
      };
    }
    const text = (row as MessageType.Text).text ?? '';
    if (metadata.system) {
      const code = metadata[META.error] as PortError['code'] | undefined;
      const error: PortError = code
        ? {code, retryable: true, detail: text}
        : (this.upstream.classifySystemRow(text) ?? {
            code: 'failed',
            retryable: true,
            detail: text,
          });
      return {...base, role: 'assistant', text: '', status: 'error', error};
    }
    if (row.author?.id !== this.upstream.userId) {
      return {
        ...base,
        role: 'assistant',
        text: cleanModelOutput(text).content,
        status: 'complete',
        ...versioned,
        ...feedback,
      };
    }
    const images = (row as MessageType.Text).imageUris ?? [];
    return {
      ...base,
      role: 'user',
      text,
      status: 'complete',
      ...(images.length > 0
        ? {
            attachments: images.map((uri, index) => ({
              id: `${row.id}:image:${index}`,
              kind: 'image' as const,
              name: uri.split('/').pop() ?? 'image',
              uri,
            })),
          }
        : null),
      ...versioned,
    };
  }

  private turnFields(
    turn: MessageType.AssistantTurn,
    live: boolean,
  ): Pick<
    ChatMessageView,
    'text' | 'status' | 'reasoning' | 'error' | 'modelId'
  > {
    const metadata = turn.metadata ?? {};
    const raw = stepText(turn.steps);
    // The renderer closes half-written markdown itself while it streams.
    const cleaned = cleanModelOutput(this.visibleText(turn), {
      streaming: live,
      repairMarkdown: false,
    });
    const reasoningText = [raw.reasoning.trim(), cleaned.reasoning ?? '']
      .filter(Boolean)
      .join('\n\n');
    const text = cleaned.content;

    const run = this.run;
    const mine = run !== null && run.turnId === turn.id;
    if (mine && live) {
      if (reasoningText && run.reasoningStartedAt === null) {
        run.reasoningStartedAt = this.now();
      }
      if (
        text &&
        run.reasoningStartedAt !== null &&
        run.thinkingMs === null &&
        cleaned.reasoningComplete
      ) {
        run.thinkingMs = this.now() - run.reasoningStartedAt;
      }
    }
    const storedMs = metadata[META.thinkingMs];
    const durationMs =
      typeof storedMs === 'number'
        ? storedMs
        : mine && run.thinkingMs !== null
          ? run.thinkingMs
          : undefined;

    let status: MessageStatus;
    let error: PortError | undefined;
    if (live) {
      status = text || reasoningText ? 'streaming' : 'pending';
    } else if (metadata[META.stopped] || this.stoppedIds.has(turn.id)) {
      status = 'stopped';
    } else if (metadata.interrupted) {
      status = 'error';
      const full =
        metadata.truncationLikely === true ||
        metadata.completionResult?.contextFull === true;
      error = {code: full ? 'context_full' : 'failed', retryable: true};
    } else {
      status = 'complete';
    }
    const modelId = metadata[META.modelId] ?? (mine ? run.modelId : undefined);
    return {
      text,
      status,
      ...(reasoningText
        ? {
            reasoning: {
              text: reasoningText,
              ...(durationMs !== undefined ? {durationMs} : null),
            },
          }
        : null),
      ...(error ? {error} : null),
      ...(typeof modelId === 'string' ? {modelId} : null),
    };
  }
}

function imageUrisOf(input: SendOptions): string[] | undefined {
  const uris = (input.attachments ?? [])
    .filter(attachment => attachment.kind === 'image')
    .map(attachment => attachment.uri);
  return uris.length > 0 ? uris : undefined;
}

// --------------------------------------------------------- the real wiring

type SendHandler = (
  message: MessageType.PartialText,
  options?: {onTurnCreated?: (turnId: string) => void},
) => Promise<unknown>;

interface Handlers {
  send: SendHandler;
  stop: () => Promise<void>;
}

let handlers: Handlers | null = null;
let handlersReady: Array<() => void> = [];
let devModels: Promise<void> | null = null;

/** The hook mounts a moment after the first screen; wait for it briefly. */
function waitForHandlers(timeoutMs = 5000): Promise<Handlers | null> {
  if (handlers) {
    return Promise.resolve(handlers);
  }
  return new Promise(resolve => {
    const timer = setTimeout(() => resolve(handlers), timeoutMs);
    handlersReady.push(() => {
      clearTimeout(timer);
      resolve(handlers);
    });
  });
}

/**
 * Debug builds: models copied into the app's documents by hand
 * (`antichat-models/`, or the spike's `spike-models/`) are offered to
 * upstream's model list. Nothing is ever downloaded here.
 */
async function registerDevModels(): Promise<void> {
  const {isDevBuild} =
    require('../spike-ui/launch') as typeof import('../spike-ui/launch');
  if (!isDevBuild()) {
    return;
  }
  const RNFS =
    require('@dr.pogodin/react-native-fs') as typeof import('@dr.pogodin/react-native-fs');
  const {modelStore} = require('../../store') as typeof import('../../store');
  const roots = [RNFS.DocumentDirectoryPath, RNFS.ExternalDirectoryPath].filter(
    (root): root is string => typeof root === 'string' && root.length > 0,
  );
  for (const root of roots) {
    for (const folder of ['antichat-models', 'spike-models']) {
      const dir = `${root}/${folder}`;
      try {
        if (!(await RNFS.exists(dir))) {
          continue;
        }
        const entries = await RNFS.readDir(dir);
        for (const entry of entries) {
          const isModel =
            // A link to a file elsewhere counts (the simulator's container).
            !entry.isDirectory() &&
            entry.name.toLowerCase().endsWith('.gguf') &&
            !entry.name.toLowerCase().includes('mmproj');
          if (!isModel) {
            continue;
          }
          const known = modelStore.models.some(
            model =>
              model.fullPath === entry.path || model.filename === entry.name,
          );
          if (!known) {
            await modelStore.addLocalModel(entry.path);
          }
        }
      } catch (error) {
        console.warn('[antichat] dev models: could not read', dir, error);
      }
    }
  }
}

function createUpstream(): ChatUpstream {
  const {chatSessionStore, modelStore} =
    require('../../store') as typeof import('../../store');
  const {assistant, user, userId} =
    require('../../utils/chat') as typeof import('../../utils/chat');
  const {l10n} = require('../../locales') as typeof import('../../locales');
  const {LLAMARN_ERROR_PATTERNS} =
    require('../../utils/llamaRnErrors') as typeof import('../../utils/llamaRnErrors');
  const {conversationAdapter} =
    require('./conversation') as typeof import('./conversation');
  const {subscribeFollowUps} =
    require('../engine/prompt/postTurn') as typeof import('../engine/prompt/postTurn');
  const {pickStarters} =
    require('../engine/prompt/starters') as typeof import('../engine/prompt/starters');

  const words = l10n.en;
  const sessionOf = (sessionId: string) =>
    chatSessionStore.sessions.find(item => item.id === sessionId);

  return {
    userId,
    activeSessionId: () => chatSessionStore.activeSessionId,
    messagesOf: sessionId => sessionOf(sessionId)?.messages,
    isGenerating: () => chatSessionStore.isGenerating,
    activeModelId: () => modelStore.activeModelId,

    async activate(sessionId) {
      if (sessionId === null) {
        chatSessionStore.resetActiveSession();
      } else {
        await chatSessionStore.setActiveSession(sessionId);
      }
    },

    async ensureModel() {
      if (!(await waitForHandlers())) {
        // Without upstream's hook nothing can be sent at all.
        return 'failed';
      }
      if (modelStore.engine ?? modelStore.context) {
        return 'ready';
      }
      if (modelStore.isContextLoading) {
        // A load is already under way (launch, or a model switch).
        await new Promise<void>(resolve => {
          const dispose = reaction(
            () => modelStore.isContextLoading,
            loading => {
              if (!loading) {
                dispose();
                resolve();
              }
            },
          );
        });
        if (modelStore.engine ?? modelStore.context) {
          return 'ready';
        }
      }
      await (devModels ?? Promise.resolve()).catch(noop);
      // On-device models only: a remote server is never picked silently.
      const usable = modelStore.availableModels.filter(
        model => model.origin !== 'remote',
      );
      const candidate =
        modelStore.activeModel ??
        usable.find(model => model.id === modelStore.lastUsedModelId) ??
        usable[0];
      if (!candidate) {
        return 'none';
      }
      try {
        await modelStore.selectModel(candidate);
      } catch (error) {
        console.warn('[antichat] model load failed', error);
        return 'failed';
      }
      return (modelStore.engine ?? modelStore.context) ? 'ready' : 'failed';
    },

    async setThinking(enabled) {
      const session = chatSessionStore.activeSessionId
        ? sessionOf(chatSessionStore.activeSessionId)
        : undefined;
      if (!session) {
        // No chat yet: upstream bakes the staged choice into the new one.
        runInAction(() => {
          chatSessionStore.newChatThinkingOverride = enabled;
          chatSessionStore.newChatReasoningEffort = undefined;
        });
        return;
      }
      const settings = await chatSessionStore.getCurrentCompletionSettings();
      if ((settings.enable_thinking ?? true) === enabled) {
        return;
      }
      await chatSessionStore.updateSessionCompletionSettings({
        ...settings,
        enable_thinking: enabled,
        reasoning: {enabled, effort: undefined},
      });
    },

    async sendMessage(message, onTurnCreated) {
      const current = await waitForHandlers();
      if (!current) {
        throw new Error('The chat session host is not mounted');
      }
      return current.send(
        {
          type: 'text',
          text: message.text,
          ...(message.imageUris?.length
            ? {imageUris: message.imageUris}
            : null),
        },
        {onTurnCreated},
      );
    },

    async stop() {
      await handlers?.stop();
    },

    removeFrom: (messageId, includeMessage) =>
      chatSessionStore.removeMessagesFromId(messageId, includeMessage),

    async addUserRow(message) {
      const row: MessageType.Text = {
        author: user,
        createdAt: Date.now(),
        id: '',
        type: 'text',
        text: message.text,
        ...(message.imageUris?.length ? {imageUris: message.imageUris} : null),
        metadata: {copyable: true, multimodal: !!message.imageUris?.length},
      };
      await chatSessionStore.addMessageToCurrentSession(row);
      return row.id;
    },

    async addErrorRow(code, detail) {
      const row: MessageType.Text = {
        author: assistant,
        createdAt: Date.now(),
        id: '',
        type: 'text',
        text: detail,
        metadata: {system: true, [META.error]: code},
      };
      await chatSessionStore.addMessageToCurrentSession(row);
      return row.id;
    },

    updateMetadata: (sessionId, messageId, metadata) =>
      chatSessionStore.updateMessage(messageId, sessionId, {metadata}),

    classifySystemRow(text) {
      if (text === words.chat.conversationReset) {
        return null;
      }
      if (text === words.chat.modelNotLoaded) {
        return {code: 'model_not_loaded', retryable: true, detail: text};
      }
      if (
        text === words.chat.toolCallTruncated ||
        LLAMARN_ERROR_PATTERNS.contextFull.test(text)
      ) {
        return {code: 'context_full', retryable: true, detail: text};
      }
      if (
        text === words.chat.speculativeInitFailed ||
        /out of memory|not enough memory|failed to allocate/i.test(text)
      ) {
        return {code: 'out_of_memory', retryable: true, detail: text};
      }
      if (text === words.common.networkError) {
        return {code: 'offline', retryable: true, detail: text};
      }
      return {code: 'failed', retryable: true, detail: text};
    },

    async versions(sessionId) {
      const thread = await conversationAdapter().getThread(sessionId);
      return new Map(
        thread.map(message => [
          message.messageId,
          {index: message.versionIndex, count: message.versionCount},
        ]),
      );
    },

    async switchVersion(sessionId, messageId, index) {
      await conversationAdapter().switchVersion(sessionId, messageId, index);
    },

    onStoreChange: listener => conversationAdapter().subscribe(listener),
    onFollowUps: listener => subscribeFollowUps(listener),
    starters: count => pickStarters(count),
  };
}

let shared: UpstreamChat | null = null;

/** The app's chat port. Follows upstream from the first call on. */
export function chatPort(): UpstreamChat {
  if (!shared) {
    const {derivedText} =
      require('../../utils/chat') as typeof import('../../utils/chat');
    shared = new UpstreamChat(createUpstream(), {visibleText: derivedText});
    shared.start();
  }
  return shared;
}

let engineInstalled = false;

/** Switches the prompt engine and the conversation store on, once. */
function installEngine(): void {
  if (engineInstalled) {
    return;
  }
  engineInstalled = true;
  const {installPromptEngine} =
    require('../engine/prompt/install') as typeof import('../engine/prompt/install');
  const {conversationAdapter} =
    require('./conversation') as typeof import('./conversation');
  const adapter = conversationAdapter();
  // The seam asks synchronously; the store answers asynchronously. Remember
  // what it said for the chats this run has seen.
  const temporary = new Map<string, boolean>();
  const remember = (sessionId: string) => {
    adapter
      .getMeta(sessionId)
      .then(meta => temporary.set(sessionId, meta?.temporary === true))
      .catch(noop);
  };
  installPromptEngine({
    environment: {
      temporary: sessionId => {
        if (!sessionId) {
          return adapter.isTemporaryPending();
        }
        if (!temporary.has(sessionId)) {
          remember(sessionId);
        }
        return temporary.get(sessionId) ?? adapter.isTemporaryPending();
      },
    },
  });
  adapter
    .ready()
    .catch(error =>
      console.warn('[antichat] conversation store did not open', error),
    );
  adapter.subscribe(() => {
    temporary.forEach((_, sessionId) => remember(sessionId));
  });
}

/**
 * Mount once, inside the app's providers, when the real backend is in use.
 * It lends upstream's `useChatSession` to the adapter (a hook needs a
 * component), keeps "which chat is open" the same in the shell and in
 * upstream, and switches the engine on. Draws nothing.
 */
export function ChatSessionHost(): null {
  const {useChatSession} =
    require('../../hooks/useChatSession') as typeof import('../../hooks/useChatSession');
  const {assistant, user} =
    require('../../utils/chat') as typeof import('../../utils/chat');
  const currentMessageInfo = useRef<{
    createdAt: number;
    id: string;
    sessionId: string;
  } | null>(null);
  const {handleSendPress, handleStopPress} = useChatSession(
    currentMessageInfo,
    user,
    assistant,
  );
  // The hook returns new closures every render; they only close over refs
  // and stores, so the newest pair is always the right one.
  const latest = useRef<Handlers>({
    send: handleSendPress,
    stop: handleStopPress,
  });
  latest.current = {send: handleSendPress, stop: handleStopPress};

  useEffect(() => {
    const {chatSessionStore} =
      require('../../store') as typeof import('../../store');
    const {shellSession} =
      require('../app/session') as typeof import('../app/session');

    handlers = {
      send: (message, options) => latest.current.send(message, options),
      stop: () => latest.current.stop(),
    };
    handlersReady.splice(0).forEach(ready => ready());
    installEngine();
    chatPort();
    devModels ??= registerDevModels().catch(noop);

    // Shell → upstream: the user opened a chat, or asked for a new one.
    const followShell = reaction(
      () => shellSession.activeConversationId,
      conversationId => {
        if (conversationId === chatSessionStore.activeSessionId) {
          return;
        }
        if (conversationId === null) {
          chatSessionStore.resetActiveSession();
        } else {
          chatSessionStore.setActiveSession(conversationId).catch(noop);
        }
      },
      {fireImmediately: true},
    );
    // Upstream → shell: the first message created the chat, or the open
    // chat was deleted.
    const followUpstream = reaction(
      () => chatSessionStore.activeSessionId,
      sessionId => {
        if (sessionId === shellSession.activeConversationId) {
          return;
        }
        if (sessionId) {
          shellSession.open(sessionId);
        } else if (
          shellSession.activeConversationId &&
          !chatSessionStore.sessions.some(
            item => item.id === shellSession.activeConversationId,
          )
        ) {
          shellSession.newChat();
        }
      },
    );
    return () => {
      followShell();
      followUpstream();
      handlers = null;
      handlersReady = [];
    };
  }, []);

  return null;
}
