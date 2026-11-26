import type {UpMessage, UpSession} from '../../types';
import type {UpstreamGateway} from '../../upstream';

export const USER = 'user-author';
export const ASSISTANT = 'assistant-author';

/**
 * Upstream's chat tables in memory, with helpers that behave like
 * upstream's ChatSessionStore (append, truncate from a message, delete one).
 */
export class FakeUpstream implements UpstreamGateway {
  readonly authors = {user: USER, assistant: ASSISTANT};
  sessions = new Map<string, UpSession>();
  messages = new Map<string, UpMessage[]>();
  private counter = 0;
  clock = 1_700_000_000_000;

  nextId(prefix: string = 'm'): string {
    return `${prefix}${++this.counter}`;
  }

  tick(ms: number = 1000): number {
    this.clock += ms;
    return this.clock;
  }

  // ---- what upstream code does on its own

  addSession(title: string = 'New Session'): string {
    const id = this.nextId('s');
    this.sessions.set(id, {id, title, createdAt: this.tick(), pinned: false});
    this.messages.set(id, []);
    return id;
  }

  say(sessionId: string, text: string, images?: string[]): UpMessage {
    const message: UpMessage = {
      id: this.nextId(),
      author: USER,
      type: 'text',
      text,
      createdAt: this.tick(),
      metadata: images ? {imageUris: images} : {},
    };
    this.messages.get(sessionId)!.push(message);
    return message;
  }

  answer(sessionId: string, text: string, reasoning?: string): UpMessage {
    const message: UpMessage = {
      id: this.nextId(),
      author: ASSISTANT,
      type: 'assistant_turn',
      createdAt: this.tick(),
      metadata: {
        steps: [
          reasoning
            ? {content: text, reasoningContent: reasoning}
            : {content: text},
        ],
        copyable: true,
      },
    };
    this.messages.get(sessionId)!.push(message);
    return message;
  }

  /** Streaming: upstream rewrites the row in place. */
  rewrite(sessionId: string, messageId: string, text: string): void {
    const list = this.messages.get(sessionId)!;
    const index = list.findIndex(message => message.id === messageId);
    const old = list[index];
    list[index] =
      old.type === 'text'
        ? {...old, text}
        : {...old, metadata: {...old.metadata, steps: [{content: text}]}};
  }

  /** ChatSessionStore.removeMessagesFromId (without the AntiChat hook). */
  truncateFrom(sessionId: string, messageId: string, include: boolean = true) {
    const list = this.messages.get(sessionId)!;
    const index = list.findIndex(message => message.id === messageId);
    this.messages.set(sessionId, list.slice(0, include ? index : index + 1));
  }

  /** ChatSessionStore.deleteMessageFromSession. */
  removeOne(sessionId: string, messageId: string): void {
    this.messages.set(
      sessionId,
      this.messages.get(sessionId)!.filter(message => message.id !== messageId),
    );
  }

  texts(sessionId: string): string[] {
    return (this.messages.get(sessionId) ?? []).map(message =>
      message.type === 'text'
        ? (message.text ?? '')
        : (message.metadata.steps?.[0]?.content ?? ''),
    );
  }

  // ---- UpstreamGateway

  async listSessions(): Promise<UpSession[]> {
    return [...this.sessions.values()].map(session => ({...session}));
  }

  async getSession(sessionId: string): Promise<UpSession | null> {
    const session = this.sessions.get(sessionId);
    return session ? {...session} : null;
  }

  async getMessages(sessionId: string): Promise<UpMessage[]> {
    return JSON.parse(JSON.stringify(this.messages.get(sessionId) ?? []));
  }

  async createSession(input: {
    title: string;
    createdAt?: number;
    pinned?: boolean;
    messages: UpMessage[];
  }): Promise<string> {
    const id = this.nextId('s');
    this.sessions.set(id, {
      id,
      title: input.title,
      createdAt: input.createdAt ?? this.tick(),
      pinned: input.pinned ?? false,
    });
    this.messages.set(id, JSON.parse(JSON.stringify(input.messages)));
    return id;
  }

  async replaceTail(
    sessionId: string,
    keep: number,
    tail: UpMessage[],
  ): Promise<void> {
    const list = this.messages.get(sessionId)!;
    this.messages.set(sessionId, [
      ...list.slice(0, keep),
      ...JSON.parse(JSON.stringify(tail)),
    ]);
  }

  async renameSession(sessionId: string, title: string): Promise<void> {
    this.sessions.get(sessionId)!.title = title;
  }

  async setPinned(sessionId: string, pinned: boolean): Promise<void> {
    this.sessions.get(sessionId)!.pinned = pinned;
  }

  async deleteSessions(sessionIds: string[]): Promise<void> {
    for (const id of sessionIds) {
      this.sessions.delete(id);
      this.messages.delete(id);
    }
  }
}
