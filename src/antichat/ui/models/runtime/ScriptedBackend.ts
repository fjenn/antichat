/**
 * A scripted stand-in for the native half of the model engine.
 *
 * It implements M5's `ModelBackend`, so the real `ModelEngine` (catalogue,
 * device classifier, selection policy, state machine) runs on top of it
 * unchanged. Only the two things that need native code are played: files
 * arriving on disk and a model being loaded. Swapping in the real backend is
 * a change in `runtime/index.ts`, nothing else.
 *
 * The pretend disk is persisted, so a download cut off by closing the app
 * continues where it stopped, and an installed model is still installed.
 */
import type {
  CatalogFile,
  DeviceSnapshot,
  DownloadTask,
  LoadRequest,
  ModelBackend,
  NetworkStatus,
  KeyValueStorage,
} from '../../../engine/models';
import {SPEED_BYTES_PER_SECOND, type ScenarioValues} from './scenario';

const GiB = 1024 ** 3;
const GB = 1000 ** 3;

const DISK_KEY = 'antichat.scripted.disk.v1';

interface DiskEntry {
  bytes: number;
  verified: boolean;
}

export interface ScriptedContext {
  modelId: string;
}

export interface ScriptedBackendOptions {
  storage: KeyValueStorage;
  scenario: ScenarioValues & {
    consumeFailure(kind: 'network' | 'checksum' | 'load'): boolean;
  };
  network: () => NetworkStatus;
  /** The phone itself, when it can be read. */
  readRealDevice?: () => Promise<DeviceSnapshot>;
  /** Free space on the phone, when it can be read. */
  readRealFreeStorage?: () => Promise<number>;
  platform?: 'ios' | 'android';
  /** Milliseconds between progress reports. */
  tickMs?: number;
  /** Speeds up verifying and loading in tests. */
  timeScale?: number;
  /** Tests: a fixed download speed instead of the scenario's. */
  bytesPerSecond?: number;
}

/** Phones the scenario can pretend to be. */
const PRETEND: Record<
  'small' | 'mid' | 'large',
  (platform: 'ios' | 'android') => DeviceSnapshot
> = {
  small: platform =>
    platform === 'ios'
      ? {
          platform,
          osVersion: '26.6',
          totalRamBytes: 3.75 * GiB,
          availableBytes: 2.1 * GB,
          machine: 'iPhone14,5',
        }
      : {
          platform,
          osVersion: '16',
          totalRamBytes: 3.7 * GiB,
          availableBytes: 1.6 * GB,
          socModel: 'MT6769',
          cpuFeatures: ['asimddp'],
        },
  mid: platform =>
    platform === 'ios'
      ? {
          platform,
          osVersion: '26.6',
          totalRamBytes: 7.5 * GiB,
          availableBytes: 3.0 * GB,
          machine: 'iPhone17,1',
        }
      : {
          platform,
          osVersion: '16',
          totalRamBytes: 7.5 * GiB,
          availableBytes: 3.2 * GB,
          socModel: 'SM8650',
          cpuFeatures: ['asimddp', 'i8mm'],
          gpuRenderer: 'Adreno (TM) 750',
        },
  large: platform =>
    platform === 'ios'
      ? {
          platform,
          osVersion: '26.6',
          totalRamBytes: 11.45 * GiB,
          availableBytes: 3.17 * GB,
          machine: 'iPhone18,1',
        }
      : {
          platform,
          osVersion: '16',
          totalRamBytes: 11.3 * GiB,
          availableBytes: 4.8 * GB,
          socModel: 'SM8750',
          cpuFeatures: ['asimddp', 'i8mm'],
          gpuRenderer: 'Adreno (TM) 830',
        },
};

const DEMO_MIN_SECONDS = 75;

const PRETEND_FREE_BYTES = 64 * GB;
/** Enough for the smallest models only. */
const TIGHT_FREE_BYTES = 2.2 * GB;
const FULL_FREE_BYTES = 0.3 * GB;

const keyOf = (file: CatalogFile): string =>
  `${file.repo}/${file.path}@${file.revision}`;

const sleep = (ms: number): Promise<void> =>
  new Promise(resolve => setTimeout(resolve, ms));

export class ScriptedBackend implements ModelBackend<ScriptedContext> {
  private disk = new Map<string, DiskEntry>();
  private restored: Promise<void> | null = null;
  private saveTimer: ReturnType<typeof setTimeout> | null = null;
  private readonly tickMs: number;
  private readonly timeScale: number;
  private readonly platform: 'ios' | 'android';
  /** Running downloads, so losing the connection can stop them. */
  private readonly running = new Set<(error: Error) => void>();

  constructor(private readonly options: ScriptedBackendOptions) {
    this.tickMs = options.tickMs ?? 250;
    this.timeScale = options.timeScale ?? 1;
    this.platform = options.platform ?? 'ios';
  }

  /** Bytes the pretend disk holds, for the Storage screen. */
  async usedBytes(): Promise<number> {
    await this.restore();
    let total = 0;
    this.disk.forEach(entry => {
      total += entry.bytes;
    });
    return total;
  }

  /** Forget every file (debug: "Start over"). */
  async wipe(): Promise<void> {
    await this.restore();
    this.disk.clear();
    await this.options.storage.removeItem(DISK_KEY);
  }

  /** The connection dropped: running downloads stop where they are. */
  connectionLost(): void {
    [...this.running].forEach(stop => stop(new Error('connection lost')));
  }

  async readDevice(): Promise<DeviceSnapshot> {
    const {scenario} = this.options;
    let snapshot: DeviceSnapshot | null = null;
    if (scenario.device === 'real' && this.options.readRealDevice) {
      try {
        snapshot = await this.options.readRealDevice();
      } catch {
        snapshot = null;
      }
    }
    snapshot ??= PRETEND[scenario.device === 'real' ? 'mid' : scenario.device](
      this.platform,
    );
    return {
      ...snapshot,
      freeStorageBytes: (await this.freeStorageBytes()) ?? undefined,
    };
  }

  network(): NetworkStatus {
    return this.options.network();
  }

  async freeStorageBytes(): Promise<number | null> {
    switch (this.options.scenario.storage) {
      case 'tight':
        return TIGHT_FREE_BYTES;
      case 'full':
        return FULL_FREE_BYTES;
    }
    let free = PRETEND_FREE_BYTES;
    try {
      free = (await this.options.readRealFreeStorage?.()) ?? free;
    } catch {
      // Keep the pretend figure.
    }
    // The scripted files take no real space; count them so the numbers add up.
    return Math.max(0, free - (await this.usedBytes()));
  }

  async bytesOnDisk(file: CatalogFile): Promise<number> {
    await this.restore();
    return this.disk.get(keyOf(file))?.bytes ?? 0;
  }

  async isVerified(file: CatalogFile): Promise<boolean> {
    await this.restore();
    return this.disk.get(keyOf(file))?.verified ?? false;
  }

  download(
    file: CatalogFile,
    onProgress: (receivedBytes: number, bytesPerSecond?: number) => void,
  ): DownloadTask {
    const key = keyOf(file);
    let timer: ReturnType<typeof setInterval> | null = null;
    let settled = false;
    let resolveDone: () => void = () => {};
    let rejectDone: (error: Error) => void = () => {};
    const done = new Promise<void>((resolve, reject) => {
      resolveDone = resolve;
      rejectDone = reject;
    });
    // The engine awaits `done` later; a cancel before that must not warn.
    done.catch(() => undefined);

    const stopTimer = () => {
      if (timer !== null) {
        clearInterval(timer);
        timer = null;
      }
    };
    const fail = (error: Error) => {
      if (settled) {
        return;
      }
      settled = true;
      stopTimer();
      this.running.delete(fail);
      this.save();
      rejectDone(error);
    };
    const failAt = this.options.scenario.consumeFailure('network')
      ? Math.min(
          file.sizeBytes,
          (this.disk.get(key)?.bytes ?? 0) + file.sizeBytes * 0.12,
        )
      : null;

    const step = () => {
      if (!this.options.network().online) {
        fail(new Error('connection lost'));
        return;
      }
      const rate = this.rateFor(file) * (0.9 + Math.random() * 0.2);
      const entry = this.disk.get(key) ?? {bytes: 0, verified: false};
      const next = Math.min(
        file.sizeBytes,
        entry.bytes + (rate * this.tickMs) / 1000,
      );
      this.disk.set(key, {bytes: next, verified: false});
      this.saveSoon();
      if (failAt !== null && next >= failAt) {
        fail(new Error('The server closed the connection'));
        return;
      }
      onProgress(next, rate);
      if (next >= file.sizeBytes) {
        settled = true;
        stopTimer();
        this.running.delete(fail);
        this.save();
        resolveDone();
      }
    };
    const start = () => {
      if (!settled && timer === null) {
        timer = setInterval(step, this.tickMs);
      }
    };

    this.running.add(fail);
    this.restore()
      .then(start)
      .catch(() => fail(new Error('disk unavailable')));

    return {
      done,
      pause: () => {
        stopTimer();
        this.save();
      },
      resume: start,
      cancel: () => fail(new Error('cancelled')),
    };
  }

  /**
   * Bytes per second for a file. The demo speed never finishes a file in
   * under `DEMO_MIN_SECONDS`, so a small model can still be watched, paused
   * and resumed.
   */
  private rateFor(file: CatalogFile): number {
    if (this.options.bytesPerSecond !== undefined) {
      return this.options.bytesPerSecond;
    }
    const {speed} = this.options.scenario;
    const rate = SPEED_BYTES_PER_SECOND[speed];
    return speed === 'demo'
      ? Math.min(rate, file.sizeBytes / DEMO_MIN_SECONDS)
      : rate;
  }

  async verify(
    file: CatalogFile,
    onProgress: (fraction: number) => void,
  ): Promise<boolean> {
    await this.restore();
    const steps = 6;
    // Hashing takes longer for a larger file, but never long.
    const total =
      Math.min(2400, 500 + (file.sizeBytes / GB) * 350) * this.timeScale;
    for (let index = 1; index <= steps; index++) {
      await sleep(total / steps);
      onProgress(index / steps);
    }
    if (this.options.scenario.consumeFailure('checksum')) {
      return false;
    }
    const entry = this.disk.get(keyOf(file));
    if (!entry || entry.bytes < file.sizeBytes) {
      return false;
    }
    this.disk.set(keyOf(file), {bytes: file.sizeBytes, verified: true});
    this.save();
    return true;
  }

  async remove(file: CatalogFile): Promise<void> {
    await this.restore();
    this.disk.delete(keyOf(file));
    this.save();
  }

  async initContext(request: LoadRequest): Promise<ScriptedContext> {
    await sleep(
      Math.min(2600, 900 + (request.weights.sizeBytes / GB) * 300) *
        this.timeScale,
    );
    if (this.loadFailureArmed(request)) {
      throw new Error('Scripted load failure');
    }
    return {modelId: request.model.id};
  }

  async releaseContext(): Promise<void> {
    await sleep(120 * this.timeScale);
  }

  private failing: {modelId: string; until: number} | null = null;

  /** Every attempt of one load fails, as a broken file would. */
  private loadFailureArmed(request: LoadRequest): boolean {
    if (this.options.scenario.consumeFailure('load')) {
      this.failing = {
        modelId: request.model.id,
        until: Date.now() + 20_000 * this.timeScale,
      };
    }
    if (
      !this.failing ||
      this.failing.modelId !== request.model.id ||
      Date.now() > this.failing.until
    ) {
      return false;
    }
    return true;
  }

  private restore(): Promise<void> {
    this.restored ??= (async () => {
      try {
        const raw = await this.options.storage.getItem(DISK_KEY);
        if (raw) {
          const entries = JSON.parse(raw) as Array<[string, DiskEntry]>;
          this.disk = new Map(entries);
        }
      } catch {
        this.disk = new Map();
      }
    })();
    return this.restored;
  }

  private saveSoon(): void {
    if (this.saveTimer === null) {
      this.saveTimer = setTimeout(() => this.save(), 1500);
    }
  }

  private save(): void {
    if (this.saveTimer !== null) {
      clearTimeout(this.saveTimer);
      this.saveTimer = null;
    }
    this.options.storage
      .setItem(DISK_KEY, JSON.stringify([...this.disk]))
      .catch(() => undefined);
  }
}
