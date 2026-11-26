import {weightsFor} from '../catalog/lookup';
import type {Backend, CatalogModel, CatalogPolicy} from '../catalog/types';
import type {DeviceProfile} from '../device/types';
import type {KeyValueStorage} from '../storage';

import type {LoadShape} from './fit';

/**
 * Init fallback chain: full GPU -> fewer GPU layers -> CPU -> CPU with the
 * smallest context -> (caller) the next smaller model.
 *
 * The control flow (bounded GPU init, releasing a context that arrives after
 * its timeout, CPU as the final attempt) is ported from Off Grid's
 * `llmHelpers.ts` and the layer sizing from its `llmDeviceLimits.ts`
 * (MIT, (c) Mohammed Ali Chherawalla).
 *
 * A failed Metal allocation can kill the process instead of throwing, so the
 * chain also keeps a journal: an attempt that was started and never finished is
 * treated as a crash and skipped on the next launch.
 */

export type AttemptKind = 'gpu' | 'gpu_reduced' | 'cpu' | 'cpu_min_context';

export interface InitAttempt {
  kind: AttemptKind;
  backend: Backend;
  gpuLayers: number;
  contextSize: number;
  vision: boolean;
  /** Null: no timeout (CPU init cannot hang on a driver). */
  timeoutMs: number | null;
}

export interface PlanOptions {
  /** Available memory right now; defaults to the launch-time budget. */
  availableBytes?: number;
  /** Attempt kinds that crashed the app before (from the journal). */
  crashed?: AttemptKind[];
}

/**
 * GPU layers that fit free memory. On iOS the offloaded weights and the Metal
 * compute buffers share system RAM, so the offload is scaled to what is free
 * after a reserve. On Android the per-RAM Adreno cap already applies.
 */
export function reducedGpuLayers(
  profile: DeviceProfile,
  modelBytes: number,
  policy: CatalogPolicy,
  availableBytes: number,
): number {
  const full = profile.gpu.maxGpuLayers;
  if (full <= 0) {
    return 0;
  }
  const half = Math.floor(full / 2);
  if (profile.snapshot.platform !== 'ios') {
    return half;
  }
  const weightBudget = availableBytes - policy.gpu.iosMetalReserveBytes;
  if (weightBudget <= 0 || modelBytes <= 0) {
    return 0;
  }
  const scaled = Math.floor(full * Math.min(1, weightBudget / modelBytes));
  // "Reduced" must be a real step down from the full attempt.
  return Math.min(scaled, half);
}

export function planInitAttempts(
  profile: DeviceProfile,
  model: CatalogModel,
  shape: LoadShape,
  policy: CatalogPolicy,
  options: PlanOptions = {},
): InitAttempt[] {
  const crashed = new Set(options.crashed ?? []);
  const available = options.availableBytes ?? profile.budget.availableBytes;
  const timeoutMs = policy.gpu.initTimeoutMs[profile.snapshot.platform];
  const attempts: InitAttempt[] = [];

  if (profile.gpu.backend !== 'cpu' && profile.gpu.maxGpuLayers > 0) {
    const gpu = {
      backend: profile.gpu.backend,
      contextSize: shape.contextSize,
      vision: shape.vision,
      timeoutMs,
    };
    attempts.push({...gpu, kind: 'gpu', gpuLayers: profile.gpu.maxGpuLayers});
    const reduced = reducedGpuLayers(
      profile,
      weightsFor(model, shape.backend).sizeBytes,
      policy,
      available,
    );
    if (reduced > 0) {
      attempts.push({...gpu, kind: 'gpu_reduced', gpuLayers: reduced});
    }
  }
  attempts.push({
    kind: 'cpu',
    backend: 'cpu',
    gpuLayers: 0,
    contextSize: shape.contextSize,
    vision: shape.vision,
    timeoutMs: null,
  });
  if (shape.contextSize > policy.minContextSize || shape.vision) {
    attempts.push({
      kind: 'cpu_min_context',
      backend: 'cpu',
      gpuLayers: 0,
      contextSize: Math.min(shape.contextSize, policy.minContextSize),
      vision: false,
      timeoutMs: null,
    });
  }

  // Skip what crashed before, and anything heavier than it: if a reduced
  // offload killed the app, the full one will too.
  const order: AttemptKind[] = ['gpu', 'gpu_reduced', 'cpu', 'cpu_min_context'];
  const worstCrash = Math.max(-1, ...[...crashed].map(k => order.indexOf(k)));
  return attempts.filter(a => order.indexOf(a.kind) > worstCrash);
}

export interface AttemptFailure {
  attempt: InitAttempt;
  message: string;
  timedOut: boolean;
}

export type InitFailureReason = 'out_of_memory' | 'load_error' | 'no_attempts';

export class InitChainError extends Error {
  constructor(
    readonly reason: InitFailureReason,
    readonly failures: AttemptFailure[],
  ) {
    super(
      failures.length > 0
        ? failures.map(f => `${f.attempt.kind}: ${f.message}`).join(' | ')
        : 'no init attempt left for this model',
    );
    this.name = 'InitChainError';
  }
}

export interface InitChainResult<C> {
  context: C;
  attempt: InitAttempt;
  /** Attempts that failed before the one that worked. */
  failures: AttemptFailure[];
}

export interface RunOptions<C> {
  attempts: InitAttempt[];
  init: (attempt: InitAttempt) => Promise<C>;
  /** Frees a context; used for one that arrives after its timeout. */
  release: (context: C) => Promise<void>;
  journal?: LoadJournal;
  modelId?: string;
  onAttempt?: (attempt: InitAttempt, index: number, total: number) => void;
}

const OOM_PATTERN = /out of memory|oom|alloc|insufficient memory|jetsam/i;

/** Run the attempts in order; the first context that initialises wins. */
export async function runInitChain<C>(
  options: RunOptions<C>,
): Promise<InitChainResult<C>> {
  const {attempts, init, release, journal, modelId = 'unknown'} = options;
  const failures: AttemptFailure[] = [];

  for (let index = 0; index < attempts.length; index++) {
    const attempt = attempts[index];
    options.onAttempt?.(attempt, index, attempts.length);
    await journal?.begin(modelId, attempt.kind);
    try {
      const context = await initWithTimeout(attempt, init, release);
      await journal?.finish();
      return {context, attempt, failures};
    } catch (error) {
      await journal?.finish();
      failures.push({
        attempt,
        message: error instanceof Error ? error.message : String(error),
        timedOut: error instanceof InitTimeoutError,
      });
    }
  }
  const reason: InitFailureReason =
    failures.length === 0
      ? 'no_attempts'
      : failures.some(f => OOM_PATTERN.test(f.message))
        ? 'out_of_memory'
        : 'load_error';
  throw new InitChainError(reason, failures);
}

class InitTimeoutError extends Error {}

async function initWithTimeout<C>(
  attempt: InitAttempt,
  init: (attempt: InitAttempt) => Promise<C>,
  release: (context: C) => Promise<void>,
): Promise<C> {
  const pending = init(attempt);
  if (attempt.timeoutMs === null) {
    return pending;
  }
  let timedOut = false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  // A context that finishes after we gave up must not stay allocated beside
  // the next attempt.
  pending
    .then(context => (timedOut ? release(context) : undefined))
    .catch(() => undefined);
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      timedOut = true;
      reject(
        new InitTimeoutError(`init timed out after ${attempt.timeoutMs} ms`),
      );
    }, attempt.timeoutMs as number);
  });
  try {
    return await Promise.race([pending, timeout]);
  } finally {
    clearTimeout(timer);
  }
}

const JOURNAL_PENDING = 'antichat.models.load.pending';
const JOURNAL_CRASHES = 'antichat.models.load.crashes';

type CrashRecord = Record<string, AttemptKind[]>;

/**
 * Remembers which load attempt was running, so a process kill during a load is
 * recognised on the next launch and that attempt is not repeated.
 */
export class LoadJournal {
  constructor(private readonly storage: KeyValueStorage) {}

  async begin(modelId: string, kind: AttemptKind): Promise<void> {
    await this.safely(() =>
      this.storage.setItem(JOURNAL_PENDING, JSON.stringify({modelId, kind})),
    );
  }

  async finish(): Promise<void> {
    await this.safely(() => this.storage.removeItem(JOURNAL_PENDING));
  }

  /**
   * Call once at launch. If an attempt was left pending, the app died during
   * it: move it to the crash list and return it.
   */
  async recoverFromCrash(): Promise<{
    modelId: string;
    kind: AttemptKind;
  } | null> {
    try {
      const raw = await this.storage.getItem(JOURNAL_PENDING);
      if (raw === null) {
        return null;
      }
      const pending = JSON.parse(raw) as {modelId: string; kind: AttemptKind};
      const crashes = await this.read();
      const kinds = new Set(crashes[pending.modelId] ?? []);
      kinds.add(pending.kind);
      crashes[pending.modelId] = [...kinds];
      await this.storage.setItem(JOURNAL_CRASHES, JSON.stringify(crashes));
      await this.storage.removeItem(JOURNAL_PENDING);
      return pending;
    } catch {
      return null;
    }
  }

  /** Attempt kinds that crashed the app for this model. */
  async crashedKinds(modelId: string): Promise<AttemptKind[]> {
    return (await this.read())[modelId] ?? [];
  }

  /** Forget crashes, e.g. after an OS or app update changed the runtime. */
  async reset(): Promise<void> {
    await this.safely(() => this.storage.removeItem(JOURNAL_CRASHES));
  }

  private async read(): Promise<CrashRecord> {
    try {
      const raw = await this.storage.getItem(JOURNAL_CRASHES);
      return raw === null ? {} : (JSON.parse(raw) as CrashRecord);
    } catch {
      return {};
    }
  }

  private async safely(work: () => Promise<void>): Promise<void> {
    try {
      await work();
    } catch {
      // The journal is best-effort; it must never block a load.
    }
  }
}
