/**
 * An in-memory stand-in for upstream's chat stores and send hook, shaped
 * like `ChatUpstream`. Rows live in MobX observables and are mutated the way
 * ChatSessionStore mutates them (newest first, the streaming step replaced
 * in place), so the adapter is driven exactly as in the app.
 */
import {observable, runInAction} from 'mobx';

import type {PortError, Starter} from '../../../contracts';
import type {AgentStep, MessageType} from '../../../../utils/types';
import {
  META,
  type ChatUpstream,
  type ModelReadiness,
  type OutgoingMessage,
} from '../../chat';

export const USER_ID = 'user';
export const ASSISTANT_ID = 'assistant';

interface PendingRun {
  sessionId: string;
  turnId: string;
  settle: () => void;
}

export class FakeChatUpstream implements ChatUpstream {
  readonly userId = USER_ID;
  readonly calls: string[] = [];
  readonly state = observable({
    active: null as string | null,
    generating: false,
    sessions: {} as Record<string, {messages: MessageType.Any[]}>,
  });
  readiness: ModelReadiness = 'ready';
  thinking: boolean | null = null;
  versionMap = new Map<string, {index: number; count: number}>();
  /** When false, `sendMessage` gives up without creating an answer row. */
  createsTurn = true;
  private nextId = 1;
  private pending: PendingRun | null = null;
  private storeListeners = new Set<() => void>();
  private followUpListeners = new Set<
    (sessionId: string | undefined, items: string[]) => void
  >();

  activeSessionId(): string | null {
    return this.state.active;
  }

  messagesOf(sessionId: string) {
    return this.state.sessions[sessionId]?.messages;
  }

  isGenerating(): boolean {
    return this.state.generating;
  }

  activeModelId(): string | undefined {
    return 'model-1';
  }

  async activate(sessionId: string | null): Promise<void> {
    this.calls.push(`activate:${sessionId}`);
    runInAction(() => {
      this.state.active = sessionId;
    });
  }

  async ensureModel(): Promise<ModelReadiness> {
    this.calls.push('ensureModel');
    return this.readiness;
  }

  async setThinking(enabled: boolean): Promise<void> {
    this.calls.push(`thinking:${enabled}`);
    this.thinking = enabled;
  }

  async sendMessage(
    message: OutgoingMessage,
    onTurnCreated: (turnId: string) => void,
  ): Promise<unknown> {
    this.calls.push(`send:${message.text}`);
    const sessionId = this.ensureSession();
    this.push(sessionId, this.userRow(message));
    if (!this.createsTurn) {
      this.push(sessionId, {
        id: this.id(),
        author: {id: ASSISTANT_ID},
        type: 'text',
        text: 'Model not loaded. Please initialize the model.',
        createdAt: this.nextId,
        metadata: {system: true},
      } as MessageType.Text);
      return undefined;
    }
    runInAction(() => {
      this.state.generating = true;
    });
    const turnId = this.id();
    this.push(sessionId, {
      id: turnId,
      author: {id: ASSISTANT_ID},
      type: 'assistant_turn',
      steps: [{partial: true}],
      createdAt: this.nextId,
      metadata: {},
    } as MessageType.AssistantTurn);
    onTurnCreated(turnId);
    return new Promise<void>(resolve => {
      this.pending = {sessionId, turnId, settle: resolve};
    });
  }

  async stop(): Promise<void> {
    this.calls.push('stop');
    this.finish();
  }

  async removeFrom(messageId: string, includeMessage: boolean): Promise<void> {
    this.calls.push(`remove:${messageId}:${includeMessage}`);
    const sessionId = this.state.active;
    if (!sessionId) {
      return;
    }
    runInAction(() => {
      const session = this.state.sessions[sessionId];
      const index = session.messages.findIndex(row => row.id === messageId);
      if (index >= 0) {
        session.messages = session.messages.slice(
          includeMessage ? index + 1 : index,
        );
      }
    });
  }

  async addUserRow(message: OutgoingMessage): Promise<string> {
    this.calls.push(`userRow:${message.text}`);
    const row = this.userRow(message);
    this.push(this.ensureSession(), row);
    return row.id;
  }

  async addErrorRow(code: PortError['code'], detail: string): Promise<string> {
    this.calls.push(`errorRow:${code}`);
    const row = {
      id: this.id(),
      author: {id: ASSISTANT_ID},
      type: 'text',
      text: detail,
      createdAt: this.nextId,
      metadata: {system: true, [META.error]: code},
    } as MessageType.Text;
    this.push(this.ensureSession(), row);
    return row.id;
  }

  async updateMetadata(
    sessionId: string,
    messageId: string,
    metadata: Record<string, unknown>,
  ): Promise<void> {
    this.calls.push(`metadata:${messageId}:${Object.keys(metadata).join(',')}`);
    runInAction(() => {
      const session = this.state.sessions[sessionId];
      const index = session.messages.findIndex(row => row.id === messageId);
      if (index >= 0) {
        // ChatSessionStore.updateMessage replaces the row object.
        session.messages[index] = {
          ...session.messages[index],
          metadata: {...session.messages[index].metadata, ...metadata},
        } as MessageType.Any;
      }
    });
  }

  classifySystemRow(text: string): PortError | null {
    if (text === 'Conversation reset!') {
      return null;
    }
    if (text.startsWith('Model not loaded')) {
      return {code: 'model_not_loaded', retryable: true, detail: text};
    }
    return {code: 'failed', retryable: true, detail: text};
  }

  async versions(): Promise<Map<string, {index: number; count: number}>> {
    return new Map(this.versionMap);
  }

  async switchVersion(
    sessionId: string,
    messageId: string,
    index: number,
  ): Promise<void> {
    this.calls.push(`switch:${sessionId}:${messageId}:${index}`);
  }

  onStoreChange(listener: () => void) {
    this.storeListeners.add(listener);
    return () => {
      this.storeListeners.delete(listener);
    };
  }

  onFollowUps(
    listener: (sessionId: string | undefined, items: string[]) => void,
  ) {
    this.followUpListeners.add(listener);
    return () => {
      this.followUpListeners.delete(listener);
    };
  }

  starters(count: number): readonly Starter[] {
    return Array.from({length: count}, (_, index) => ({
      id: `s${index}`,
      category: 'learn' as const,
      label: `Starter ${index}`,
      prompt: `Prompt ${index}`,
    }));
  }

  // ---------------------------------------------------------- test controls

  /** A stored chat: `rows` oldest first, as a reader would write them. */
  seed(sessionId: string, rows: MessageType.Any[]): void {
    runInAction(() => {
      this.state.sessions[sessionId] = {messages: [...rows].reverse()};
    });
  }

  open(sessionId: string | null): void {
    runInAction(() => {
      this.state.active = sessionId;
    });
  }

  user(text: string, id = this.id()): MessageType.Text {
    return {...this.userRow({text}), id};
  }

  turn(
    steps: AgentStep[],
    metadata: Record<string, unknown> = {},
    id = this.id(),
  ): MessageType.AssistantTurn {
    return {
      id,
      author: {id: ASSISTANT_ID},
      type: 'assistant_turn',
      steps,
      createdAt: this.nextId,
      metadata,
    } as MessageType.AssistantTurn;
  }

  system(text: string, id = this.id()): MessageType.Text {
    return {
      id,
      author: {id: ASSISTANT_ID},
      type: 'text',
      text,
      createdAt: this.nextId,
      metadata: {system: true},
    } as MessageType.Text;
  }

  /** What `updateActiveStepStreaming` does: the last step is replaced. */
  token(partial: Partial<AgentStep>): void {
    const run = this.pending;
    if (!run) {
      throw new Error('No run to stream into');
    }
    runInAction(() => {
      const turn = this.state.sessions[run.sessionId].messages.find(
        row => row.id === run.turnId,
      ) as MessageType.AssistantTurn;
      const last = turn.steps.length - 1;
      turn.steps[last] = {...turn.steps[last], ...partial};
    });
  }

  /** The run ends: the flag clears first, then the send promise settles. */
  finish(): void {
    const run = this.pending;
    runInAction(() => {
      this.state.generating = false;
    });
    if (run) {
      this.pending = null;
      run.settle();
    }
  }

  emitStoreChange(): void {
    this.storeListeners.forEach(listener => listener());
  }

  emitFollowUps(sessionId: string | undefined, items: string[]): void {
    this.followUpListeners.forEach(listener => listener(sessionId, items));
  }

  private ensureSession(): string {
    if (this.state.active) {
      return this.state.active;
    }
    const sessionId = `chat-${this.nextId++}`;
    runInAction(() => {
      this.state.sessions[sessionId] = {messages: []};
      this.state.active = sessionId;
    });
    return sessionId;
  }

  private push(sessionId: string, row: MessageType.Any): void {
    runInAction(() => {
      this.state.sessions[sessionId].messages.unshift(row);
    });
  }

  private userRow(message: OutgoingMessage): MessageType.Text {
    return {
      id: this.id(),
      author: {id: USER_ID},
      type: 'text',
      text: message.text,
      createdAt: this.nextId,
      ...(message.imageUris ? {imageUris: message.imageUris} : null),
      metadata: {},
    } as MessageType.Text;
  }

  private id(): string {
    return `m${this.nextId++}`;
  }
}

/** Lets queued promise callbacks run. */
export async function settle(times = 6): Promise<void> {
  for (let i = 0; i < times; i++) {
    await Promise.resolve();
  }
}
