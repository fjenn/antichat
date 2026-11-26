/**
 * Coalesces model tokens into at most one flush per frame.
 *
 * llama.rn calls back once per token on the JS thread. Rendering each token is
 * wasted work: at 60 tok/s on a 60 Hz screen several tokens land between two
 * frames, and every flush is a native call plus a layout pass. The batcher
 * keeps the pending text in a string and hands it to the sink once per frame
 * (or per `minIntervalMs`), so the cost per frame is constant however fast the
 * model runs.
 */
export type BatchSink = (chunk: string, tokens: number) => void;

export type Scheduler = (callback: () => void) => unknown;

export type BatcherStats = {
  tokens: number;
  flushes: number;
  /** Largest number of tokens delivered in one flush. */
  maxBatch: number;
};

const nowMs = (): number =>
  typeof performance === 'object' ? performance.now() : Date.now();

export class TokenBatcher {
  private pending = '';
  private pendingTokens = 0;
  private scheduled = false;
  private closed = false;
  private lastFlush = -Infinity;
  readonly stats: BatcherStats = {tokens: 0, flushes: 0, maxBatch: 0};

  constructor(
    private readonly sink: BatchSink,
    private readonly options: {
      /** Frame scheduler; requestAnimationFrame in the app, a fake in tests. */
      schedule?: Scheduler;
      /** Lower bound between flushes. 0 = every frame. */
      minIntervalMs?: number;
      now?: () => number;
    } = {},
  ) {}

  push(token: string): void {
    if (this.closed || token === '') {
      return;
    }
    this.pending += token;
    this.pendingTokens += 1;
    this.stats.tokens += 1;
    this.arm();
  }

  /** Delivers what is pending now and stops accepting tokens. */
  end(): void {
    if (this.closed) {
      return;
    }
    this.flush(true);
    this.closed = true;
  }

  private arm() {
    if (this.scheduled) {
      return;
    }
    this.scheduled = true;
    const schedule = this.options.schedule ?? requestAnimationFrame;
    schedule(() => {
      this.scheduled = false;
      this.flush(false);
    });
  }

  private flush(force: boolean) {
    if (this.closed || this.pendingTokens === 0) {
      return;
    }
    const now = (this.options.now ?? nowMs)();
    const wait = this.options.minIntervalMs ?? 0;
    if (!force && now - this.lastFlush < wait) {
      this.arm();
      return;
    }
    const chunk = this.pending;
    const tokens = this.pendingTokens;
    this.pending = '';
    this.pendingTokens = 0;
    this.lastFlush = now;
    this.stats.flushes += 1;
    this.stats.maxBatch = Math.max(this.stats.maxBatch, tokens);
    this.sink(chunk, tokens);
  }
}
