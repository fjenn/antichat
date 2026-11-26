/**
 * One queue for everything that wants the model after a reply.
 *
 * Title, follow-ups, context compaction and the memory capture all start
 * when the same answer finishes and all need the generation lease. Run
 * separately they collide: the second finds the lease taken and has to
 * retry on a timer. Here they register once and run one after another,
 * lowest `order` first, each under its own lease.
 *
 * The user always wins: a job that started gives way through the lease it
 * holds, and jobs still waiting are dropped when a new send begins.
 */
export interface AfterReplyJob {
  id: string;
  /** Lower runs first. Default 100. */
  order?: number;
  run(): Promise<void>;
}

export interface AfterReplyQueueOptions {
  /** True while the user's own generation runs (jobs wait, then drop). */
  isBusy?: () => boolean;
  setTimer?: (fn: () => void, ms: number) => unknown;
  clearTimer?: (handle: unknown) => void;
}

export class AfterReplyQueue {
  private readonly jobs = new Map<string, AfterReplyJob>();
  private timer: unknown = null;
  private generation = 0;
  private running: Promise<void> | null = null;

  constructor(private readonly options: AfterReplyQueueOptions = {}) {}

  /** Adds a job (same id replaces). Returns the function that removes it. */
  register(job: AfterReplyJob): () => void {
    this.jobs.set(job.id, job);
    return () => {
      if (this.jobs.get(job.id) === job) {
        this.jobs.delete(job.id);
      }
    };
  }

  get size(): number {
    return this.jobs.size;
  }

  /** A reply finished: run every job once, `delayMs` from now. */
  schedule(delayMs: number = 400): void {
    this.cancel();
    const generation = this.generation;
    this.timer = (this.options.setTimer ?? setTimeout)(() => {
      this.timer = null;
      this.running = this.drain(generation).finally(() => {
        this.running = null;
      });
    }, delayMs);
  }

  /** A new send started (or the chat changed): drop what has not begun. */
  cancel(): void {
    this.generation++;
    if (this.timer !== null) {
      (this.options.clearTimer ?? (clearTimeout as (h: unknown) => void))(
        this.timer,
      );
      this.timer = null;
    }
  }

  /** Resolves when the pass in flight (if any) has ended. Tests. */
  async idle(): Promise<void> {
    await this.running;
  }

  private async drain(generation: number): Promise<void> {
    const ordered = [...this.jobs.values()].sort(
      (a, b) => (a.order ?? 100) - (b.order ?? 100),
    );
    for (const job of ordered) {
      if (generation !== this.generation || this.options.isBusy?.()) {
        return;
      }
      try {
        await job.run();
      } catch (error) {
        console.warn(`[antichat] after-reply job ${job.id} failed`, error);
      }
    }
  }
}

/** The app's queue. `installPostTurnHooks` drives it. */
export const afterReplyQueue = new AfterReplyQueue();
