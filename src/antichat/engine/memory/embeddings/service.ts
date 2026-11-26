/**
 * Lifecycle of the embedding model beside the chat model.
 *
 * The model is never resident "just in case":
 *  - it loads on first use and is released after an idle period that
 *    depends on the phone's class (never kept on 6 GB phones);
 *  - it does not load at all where memory does not allow it (class A, or
 *    when the measured free memory is below the model's need plus a
 *    reserve), in which case callers get `null` and fall back to keyword
 *    search;
 *  - it is released at once on a memory warning or when the app goes to
 *    the background.
 * Loads are single-flight: concurrent callers share one context.
 */
import {DEFAULT_EMBEDDING_MODEL, type EmbeddingModelSpec} from './catalog';
import {
  createLlamaEmbedder,
  type EmbeddingContext,
  type EmbeddingContextLoader,
} from './llamaEmbedder';
import type {Embedder, EmbedderProvider} from './types';

export type EmbeddingDeviceClass = 'A' | 'B' | 'C' | 'D' | 'E';

export interface EmbeddingPolicy {
  /** May the embedding model run on this class at all? */
  allowed: boolean;
  /** Keep it loaded this long after the last use (ms); 0 = release at once. */
  idleReleaseMs: number;
  /** Free memory that must remain after loading (bytes). */
  reserveBytes: number;
  /** Use it for the per-message memory lookup (not only for indexing). */
  queryTime: boolean;
}

const MB = 1024 * 1024;

/**
 * Per class (docs/antichat/m5-device-table.md, column "Embeddings beside
 * chat"). The numbers are starting points for spike S2.
 *  A (4 GB, LFM3 at 4k): no. Keyword search only.
 *  B (6 GB): index at idle and release immediately; no query-time use, so a
 *    send never waits for a model load.
 *  C (8 GB): query-time use, released after 60 s idle.
 *  D/E (12 GB+): query-time use, released after 5 minutes idle.
 */
export function embeddingPolicyFor(
  deviceClass: EmbeddingDeviceClass,
): EmbeddingPolicy {
  switch (deviceClass) {
    case 'A':
      return {
        allowed: false,
        idleReleaseMs: 0,
        reserveBytes: 0,
        queryTime: false,
      };
    case 'B':
      return {
        allowed: true,
        idleReleaseMs: 0,
        reserveBytes: 500 * MB,
        queryTime: false,
      };
    case 'C':
      return {
        allowed: true,
        idleReleaseMs: 60_000,
        reserveBytes: 400 * MB,
        queryTime: true,
      };
    default:
      return {
        allowed: true,
        idleReleaseMs: 300_000,
        reserveBytes: 400 * MB,
        queryTime: true,
      };
  }
}

export interface EmbeddingServiceOptions {
  /** Absolute path of the GGUF, or null while the file is not installed. */
  modelPath: () => string | null | Promise<string | null>;
  loader: EmbeddingContextLoader;
  deviceClass: () => EmbeddingDeviceClass;
  spec?: EmbeddingModelSpec;
  /** Free memory right now, in bytes (M5's probe). Absent = not checked. */
  availableMemory?: () => number | null | Promise<number | null>;
  /** True while the chat model is generating: loading then is postponed. */
  isChatBusy?: () => boolean;
  policy?: (deviceClass: EmbeddingDeviceClass) => EmbeddingPolicy;
  setTimer?: (fn: () => void, ms: number) => unknown;
  clearTimer?: (handle: unknown) => void;
}

export type EmbeddingPurpose = 'query' | 'index';

export type EmbeddingUnavailable =
  | 'no-model-file'
  | 'device-class'
  | 'low-memory'
  | 'chat-busy'
  | 'not-for-queries'
  | 'load-failed';

export class EmbeddingService {
  readonly spec: EmbeddingModelSpec;
  private readonly options: EmbeddingServiceOptions;
  private context: EmbeddingContext | null = null;
  private embedder: Embedder | null = null;
  private loading: Promise<Embedder | null> | null = null;
  private users = 0;
  private timer: unknown = null;
  /** Why the last `acquire` returned null. */
  lastUnavailable: EmbeddingUnavailable | null = null;
  loads = 0;

  constructor(options: EmbeddingServiceOptions) {
    this.options = options;
    this.spec = options.spec ?? DEFAULT_EMBEDDING_MODEL;
  }

  get loaded(): boolean {
    return this.context !== null;
  }

  private policy(): EmbeddingPolicy {
    return (this.options.policy ?? embeddingPolicyFor)(
      this.options.deviceClass(),
    );
  }

  private stopTimer(): void {
    if (this.timer !== null) {
      (this.options.clearTimer ?? (clearTimeout as (h: unknown) => void))(
        this.timer,
      );
      this.timer = null;
    }
  }

  /** Why the model may not load now, or null when it may. */
  async unavailable(
    purpose: EmbeddingPurpose,
  ): Promise<EmbeddingUnavailable | null> {
    const policy = this.policy();
    if (!policy.allowed) {
      return 'device-class';
    }
    if (purpose === 'query' && !policy.queryTime) {
      return 'not-for-queries';
    }
    if (!(await this.options.modelPath())) {
      return 'no-model-file';
    }
    if (this.context) {
      return null;
    }
    if (purpose === 'index' && this.options.isChatBusy?.()) {
      return 'chat-busy';
    }
    const free = await this.options.availableMemory?.();
    if (
      typeof free === 'number' &&
      free < this.spec.ramBytes + policy.reserveBytes
    ) {
      return 'low-memory';
    }
    return null;
  }

  private async load(): Promise<Embedder | null> {
    const modelPath = await this.options.modelPath();
    if (!modelPath) {
      this.lastUnavailable = 'no-model-file';
      return null;
    }
    try {
      this.context = await this.options.loader({modelPath, spec: this.spec});
      this.embedder = createLlamaEmbedder(this.spec, this.context);
      this.loads++;
      return this.embedder;
    } catch (error) {
      console.warn('[antichat] embedding model failed to load', error);
      this.context = null;
      this.embedder = null;
      this.lastUnavailable = 'load-failed';
      return null;
    }
  }

  /**
   * Runs `work` with the embedder, loading the model if allowed. Resolves
   * null (and `work` is not called) when it may not run.
   */
  async use<T>(
    purpose: EmbeddingPurpose,
    work: (embedder: Embedder) => Promise<T>,
  ): Promise<T | null> {
    const reason = await this.unavailable(purpose);
    if (reason) {
      this.lastUnavailable = reason;
      return null;
    }
    this.stopTimer();
    this.users++;
    try {
      if (!this.embedder) {
        this.loading = this.loading ?? this.load();
        const loaded = await this.loading;
        this.loading = null;
        if (!loaded) {
          return null;
        }
      }
      this.lastUnavailable = null;
      return await work(this.embedder!);
    } finally {
      this.users--;
      if (this.users === 0) {
        this.scheduleRelease();
      }
    }
  }

  private scheduleRelease(): void {
    const {idleReleaseMs} = this.policy();
    if (idleReleaseMs <= 0) {
      this.release().catch(() => {});
      return;
    }
    this.stopTimer();
    this.timer = (this.options.setTimer ?? setTimeout)(() => {
      this.timer = null;
      if (this.users === 0) {
        this.release().catch(() => {});
      }
    }, idleReleaseMs);
  }

  /** Frees the model now (memory warning, app backgrounded, model swap). */
  async release(): Promise<void> {
    this.stopTimer();
    const context = this.context;
    this.context = null;
    this.embedder = null;
    if (context) {
      await context.release();
    }
  }

  /**
   * An `EmbedderProvider` for the memory code: an embedder whose calls go
   * through `use`, or null when the model may not run for `purpose`.
   */
  provider(purpose: EmbeddingPurpose): EmbedderProvider {
    return async () => {
      const reason = await this.unavailable(purpose);
      if (reason) {
        this.lastUnavailable = reason;
        return null;
      }
      return {
        id: this.spec.id,
        dims: this.spec.dims,
        embed: async (texts, kind) => {
          const result = await this.use(purpose, embedder =>
            embedder.embed(texts, kind),
          );
          if (!result) {
            throw new Error(
              `Embedding model unavailable: ${this.lastUnavailable}`,
            );
          }
          return result;
        },
      };
    };
  }
}

export function createEmbeddingService(
  options: EmbeddingServiceOptions,
): EmbeddingService {
  return new EmbeddingService(options);
}
