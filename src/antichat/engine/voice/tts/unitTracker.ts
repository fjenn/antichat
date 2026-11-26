import type {TtsStreamCallbacks} from './types';

/** Maps stream character offsets back to the units that were appended. */
export class UnitTracker {
  private readonly ranges: {id: number; start: number; end: number}[] = [];
  private length = 0;
  private started = new Set<number>();
  private ended = new Set<number>();

  constructor(private readonly callbacks: TtsStreamCallbacks) {}

  /** Returns the text to append for unit `id`. */
  add(id: number, text: string): string {
    const piece = text + ' ';
    this.ranges.push({id, start: this.length, end: this.length + piece.length});
    this.length += piece.length;
    return piece;
  }

  /** A chunk covering `[start, end)` of the stream text started playing. */
  progress(start: number, end: number): void {
    for (const range of this.ranges) {
      if (range.end <= start) {
        this.finish(range.id);
      } else if (range.start < end && !this.started.has(range.id)) {
        // Units inside one chunk play back to back: the earlier ones are
        // closed when the next chunk starts.
        this.started.add(range.id);
        this.callbacks.onUnitStart(range.id);
      }
    }
  }

  /** Everything was spoken. */
  drain(): void {
    this.ranges.forEach(range => {
      if (!this.started.has(range.id)) {
        this.started.add(range.id);
        this.callbacks.onUnitStart(range.id);
      }
      this.finish(range.id);
    });
  }

  private finish(id: number): void {
    if (this.started.has(id) && !this.ended.has(id)) {
      this.ended.add(id);
      this.callbacks.onUnitEnd(id);
    }
  }
}
