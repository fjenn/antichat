import {Emitter} from '../common';
import type {
  ConversationPort,
  ConversationSection,
  ConversationView,
  SearchHit,
  SearchOptions,
} from '../conversation';
import {buildSections} from '../dateBuckets';

const HOUR = 60 * 60 * 1000;
const DAY = 24 * HOUR;

/** [title, age in ms, pinned] — a believable history for the drawer. */
const SEED: Array<[string, number, boolean?]> = [
  ['Weekend trip to Lisbon', 2 * DAY, true],
  ['Sourdough starter schedule', 9 * DAY, true],
  ['Explain transformers simply', 0.4 * HOUR],
  ['Cover letter for a design role', 3 * HOUR],
  ['Fix a flaky Jest test', 5 * HOUR],
  ['Birthday message for Mum', 1 * DAY + 2 * HOUR],
  ['Compare two phone plans', 1 * DAY + 6 * HOUR],
  ['Spanish practice: ordering food', 3 * DAY],
  ['Summary of the meeting notes', 4 * DAY],
  ['Why is the sky blue at noon and red at sunset?', 5 * DAY],
  ['Budget for the kitchen renovation', 6 * DAY],
  ['Regex for dates', 12 * DAY],
  ['Names for a grey cat', 16 * DAY],
  ['Half-marathon training plan', 23 * DAY],
  ['How do tides work', 41 * DAY],
  ['Gift ideas under 30 euros', 67 * DAY],
];

export interface FakeConversationsOptions {
  /** Start with no chats at all. */
  empty?: boolean;
  now?: () => number;
}

export class FakeConversations extends Emitter implements ConversationPort {
  conversations: ConversationView[] = [];
  private nextId = 1;
  private readonly now: () => number;

  constructor(options: FakeConversationsOptions = {}) {
    super();
    this.now = options.now ?? Date.now;
    if (!options.empty) {
      const now = this.now();
      this.conversations = SEED.map(([title, age, pinned]) =>
        this.make({title, updatedAt: now - age, createdAt: now - age, pinned}),
      );
    }
  }

  sections(now: number = this.now()): ConversationSection[] {
    return buildSections(this.conversations, now);
  }

  get(id: string): ConversationView | undefined {
    return this.conversations.find(conversation => conversation.id === id);
  }

  archived(): readonly ConversationView[] {
    return this.conversations.filter(conversation => conversation.archived);
  }

  async create(
    options: {temporary?: boolean; projectId?: string} = {},
  ): Promise<ConversationView> {
    const now = this.now();
    const conversation = this.make({
      title: '',
      updatedAt: now,
      createdAt: now,
      temporary: options.temporary,
      projectId: options.projectId,
    });
    this.conversations = [conversation, ...this.conversations];
    this.emit();
    return conversation;
  }

  async rename(id: string, title: string): Promise<void> {
    this.patch(id, {title: title.trim()});
  }

  async setPinned(id: string, pinned: boolean): Promise<void> {
    this.patch(id, {pinned});
  }

  async setArchived(id: string, archived: boolean): Promise<void> {
    this.patch(id, {archived, pinned: false});
  }

  async setLocked(id: string, locked: boolean): Promise<void> {
    this.patch(id, {locked});
  }

  async saveTemporary(id: string): Promise<void> {
    this.patch(id, {temporary: false});
  }

  async remove(id: string): Promise<void> {
    this.conversations = this.conversations.filter(
      conversation => conversation.id !== id,
    );
    this.emit();
  }

  async removeAll(): Promise<void> {
    this.conversations = [];
    this.emit();
  }

  async branch(id: string, messageId: string): Promise<ConversationView> {
    const source = this.get(id);
    const now = this.now();
    const conversation = this.make({
      title: source?.title ?? '',
      updatedAt: now,
      createdAt: now,
      branchedFrom: {conversationId: id, messageId},
    });
    this.conversations = [conversation, ...this.conversations];
    this.emit();
    return conversation;
  }

  async search(
    query: string,
    options: SearchOptions = {},
  ): Promise<SearchHit[]> {
    const needle = query.trim().toLowerCase();
    if (!needle) {
      return [];
    }
    const hits: SearchHit[] = [];
    for (const conversation of this.conversations) {
      const at = conversation.title.toLowerCase().indexOf(needle);
      if (at >= 0 && !conversation.temporary) {
        hits.push({conversation, matches: [[at, at + needle.length]]});
      }
    }
    return hits.slice(0, options.limit ?? 50);
  }

  /** Used by the fake chat: a message moves its chat to the top. */
  touch(id: string, title?: string): void {
    const current = this.get(id);
    this.patch(id, {
      updatedAt: this.now(),
      title: current?.title || title || '',
    });
  }

  private make(
    fields: Partial<ConversationView> & {updatedAt: number; createdAt: number},
  ): ConversationView {
    return {
      id: `c${this.nextId++}`,
      title: '',
      pinned: false,
      archived: false,
      temporary: false,
      locked: false,
      ...fields,
      // `pinned: undefined` from the seed must not override the default.
      ...(fields.pinned === undefined ? {pinned: false} : null),
      ...(fields.temporary === undefined ? {temporary: false} : null),
    };
  }

  private patch(id: string, fields: Partial<ConversationView>): void {
    this.conversations = this.conversations.map(conversation =>
      conversation.id === id ? {...conversation, ...fields} : conversation,
    );
    this.emit();
  }
}
