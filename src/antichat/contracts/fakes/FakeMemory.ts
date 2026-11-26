import {Emitter} from '../common';
import type {MemoryPort, MemoryView} from '../memory';

const DAY = 24 * 60 * 60 * 1000;

const SEED: Array<[string, MemoryView['origin'], number]> = [
  ['Is vegetarian', 'saved', 20 * DAY],
  ['Works as a product designer', 'learned', 12 * DAY],
  ['Prefers short answers with examples', 'learned', 5 * DAY],
  ['Is training for a half-marathon in spring', 'learned', 2 * DAY],
];

export class FakeMemory extends Emitter implements MemoryPort {
  enabled = true;
  memories: MemoryView[];
  private nextId = 1;
  private readonly used = new Map<string, string[]>();

  constructor(private readonly now: () => number = Date.now) {
    super();
    const time = now();
    this.memories = SEED.map(([text, origin, age]) => ({
      id: `mem${this.nextId++}`,
      text,
      origin,
      createdAt: time - age,
      updatedAt: time - age,
    }));
  }

  async setEnabled(enabled: boolean): Promise<void> {
    this.enabled = enabled;
    this.emit();
  }

  async add(text: string): Promise<MemoryView> {
    const time = this.now();
    const memory: MemoryView = {
      id: `mem${this.nextId++}`,
      text: text.trim(),
      origin: 'saved',
      createdAt: time,
      updatedAt: time,
    };
    this.memories = [memory, ...this.memories];
    this.emit();
    return memory;
  }

  async update(id: string, text: string): Promise<void> {
    this.memories = this.memories.map(memory =>
      memory.id === id
        ? {...memory, text: text.trim(), updatedAt: this.now()}
        : memory,
    );
    this.emit();
  }

  async remove(id: string): Promise<void> {
    this.memories = this.memories.filter(memory => memory.id !== id);
    this.emit();
  }

  async removeAll(): Promise<void> {
    this.memories = [];
    this.emit();
  }

  usedBy(messageId: string): readonly MemoryView[] {
    const ids = this.used.get(messageId) ?? [];
    return this.memories.filter(memory => ids.includes(memory.id));
  }

  /** Test and demo control: mark memories as used by an answer. */
  markUsed(messageId: string, memoryIds: string[]): void {
    this.used.set(messageId, memoryIds);
    this.emit();
  }
}
