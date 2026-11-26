import {
  action,
  computed,
  makeObservable,
  observable,
  ObservableMap,
  runInAction,
} from 'mobx';

import {buildCapabilityMap, CapabilityMap} from './capabilities';
import {bundledCatalog} from './catalog/bundledCatalog';
import {
  filesFor,
  getClass,
  getModel,
  isRevoked,
  weightsFor,
} from './catalog/lookup';
import type {CatalogStore} from './catalog/store';
import type {
  Catalog,
  CatalogFile,
  CatalogModel,
  DeviceClass,
} from './catalog/types';
import {classifyDevice} from './device/classify';
import type {DeviceProfile, DeviceSnapshot} from './device/types';
import {
  CalibrationRecord,
  judgeCalibration,
  SpeedMeter,
} from './policy/calibration';
import {decideDownload, NetworkStatus, planFirstRun} from './policy/download';
import {
  InitAttempt,
  InitChainError,
  LoadJournal,
  planInitAttempts,
  runInitChain,
} from './policy/initChain';
import {MemoryPressure, reactToLowMemory} from './policy/lowMemory';
import {storeFit} from './policy/storeFit';
import {
  bestShapeFor,
  DemotionReason,
  ModelChoice,
  Selection,
  selectModel,
  selectUnrestricted,
  stepDown,
} from './policy/select';
import type {
  EnginePhase,
  ModelNotice,
  ModelPort,
  ModelView,
  PressureContext,
} from './port';
import {
  FailureReason,
  isInstalled,
  ModelEvent,
  ModelState,
  NOT_INSTALLED,
  transition,
} from './state';
import {KeyValueStorage, MemoryStorage} from './storage';

/** A running file download. `done` settles when the file is complete. */
export interface DownloadTask {
  done: Promise<void>;
  pause(): void;
  resume(): void;
  /** Stops the download; `done` then rejects. Partial data may be kept. */
  cancel(): void;
}

export interface LoadRequest {
  model: CatalogModel;
  weights: CatalogFile;
  projector?: CatalogFile;
  attempt: InitAttempt;
}

/**
 * What the engine needs from the platform. The native half of M5 implements
 * this over llama.rn and the download manager; tests use a fake.
 */
export interface ModelBackend<C = unknown> {
  readDevice(): Promise<DeviceSnapshot>;
  network(): NetworkStatus;
  freeStorageBytes(): Promise<number | null>;
  /** Resolves when the app is on screen (at once if it already is). */
  waitUntilForeground?(): Promise<void>;
  /** A fresh available-memory reading, taken just before a load. */
  availableMemoryBytes?(): Promise<number>;
  /** Bytes of the file on disk, complete or partial; 0 when absent. */
  bytesOnDisk(file: CatalogFile): Promise<number>;
  /** The file is complete and passed its hash check earlier. */
  isVerified(file: CatalogFile): Promise<boolean>;
  /** Start or continue downloading one file. Progress is bytes on disk. */
  download(
    file: CatalogFile,
    onProgress: (receivedBytes: number, bytesPerSecond?: number) => void,
  ): DownloadTask;
  /** Hash the file against `file.sha256` and remember a pass. */
  verify(
    file: CatalogFile,
    onProgress: (fraction: number) => void,
  ): Promise<boolean>;
  remove(file: CatalogFile): Promise<void>;
  initContext(request: LoadRequest): Promise<C>;
  /** Must resolve only once the memory is really back. */
  releaseContext(context: C): Promise<void>;
  releaseProjector?(context: C): Promise<void>;
  releaseAux?(which: string): Promise<void>;
}

export interface ModelEngineOptions<C> {
  backend: ModelBackend<C>;
  storage?: KeyValueStorage;
  /** Without a store the bundled catalogue is used. */
  catalogStore?: CatalogStore;
  now?: () => number;
}

interface Persisted {
  demoted: Record<string, DemotionReason>;
  calibration: Record<string, CalibrationRecord>;
}

interface ActiveDownload {
  task: DownloadTask | null;
  cancelled: boolean;
  allowMetered: boolean;
  thenLoad: boolean;
}

const HISTORY_KEY = 'antichat.models.history';

/** Restarts of a broken transfer before the user is asked to retry. */
const MAX_AUTO_RESTARTS = 2;

export class ModelEngine<C = unknown> implements ModelPort {
  private readonly autoRestarts = new Map<string, number>();
  phase: EnginePhase = 'idle';
  device: DeviceProfile | null = null;
  selection: Selection | null = null;
  unrestrictedChoice: ModelChoice | null = null;
  activeModelId: string | null = null;
  notices: ModelNotice[] = [];
  readonly states: ObservableMap<string, ModelState> = observable.map(
    {},
    {deep: false},
  );

  private catalog: Catalog = bundledCatalog;
  private persisted: Persisted = {demoted: {}, calibration: {}};
  private readonly backend: ModelBackend<C>;
  private readonly storage: KeyValueStorage;
  private readonly journal: LoadJournal;
  private readonly now: () => number;
  private readonly downloads = new Map<string, ActiveDownload>();
  private readonly listeners = new Set<() => void>();
  private readonly starting = new Set<string>();
  /** Models whose download should end in a load, across failures and retries. */
  private readonly loadWhenInstalled = new Set<string>();
  private context: {modelId: string; handle: C; choice: ModelChoice} | null =
    null;
  private meter: SpeedMeter | null = null;
  private releaseWhenIdle = false;
  private recentReleases: number[] = [];
  private noticeCounter = 0;

  constructor(private readonly options: ModelEngineOptions<C>) {
    this.backend = options.backend;
    this.storage = options.storage ?? new MemoryStorage();
    this.journal = new LoadJournal(this.storage);
    this.now = options.now ?? Date.now;
    makeObservable(this, {
      phase: observable,
      device: observable.ref,
      selection: observable.ref,
      unrestrictedChoice: observable.ref,
      activeModelId: observable,
      notices: observable.ref,
      deviceClass: computed,
      capabilities: computed,
      models: computed,
      recommendedModelId: computed,
      unrestrictedModelId: computed,
      dismissNotice: action,
    });
  }

  // ---- observable reads ---------------------------------------------------

  get deviceClass(): DeviceClass | null {
    return this.device?.deviceClass ?? null;
  }

  get recommendedModelId(): string | null {
    return this.selection?.model.id ?? null;
  }

  get unrestrictedModelId(): string | null {
    return this.unrestrictedChoice?.model.id ?? null;
  }

  get capabilities(): CapabilityMap | null {
    if (!this.device || !this.selection) {
      return null;
    }
    const active = this.activeModelId
      ? this.choiceFor(this.activeModelId)
      : null;
    const choice = active ?? this.selection;
    return buildCapabilityMap(
      this.device,
      this.catalog,
      choice.model,
      choice.shape,
    );
  }

  get models(): ModelView[] {
    if (!this.device) {
      return [];
    }
    const recommended = this.recommendedModelId;
    const views = this.catalog.models
      .filter(model => !isRevoked(this.catalog, model))
      .map((model): ModelView => {
        const choice = this.choiceFor(model.id);
        const fit = storeFit(model, this.device!, this.catalog, choice);
        return {
          id: model.id,
          displayName: model.displayName,
          downloadBytes:
            choice?.downloadBytes ??
            weightsFor(model, this.device!.gpu.backend).sizeBytes,
          unrestricted: model.unrestricted,
          licenceName: model.licence.name,
          openSource: model.licence.openSource,
          licenceNotice: model.licence.notice,
          recommended: model.id === recommended,
          supported: choice !== null && fit.level !== 'too_large',
          vision: choice?.shape.vision ?? false,
          fit: fit.level,
          needsRamGb: fit.needsRamGb,
          summary: model.summary,
          heldBack: model.heldBack,
          baseModel: model.baseModel,
          languages: model.languages,
          sizedFor: model.tier,
          weightsBytes: weightsFor(model, this.device!.gpu.backend).sizeBytes,
          measured:
            this.catalog.ladder.includes(model.id) ||
            this.catalog.unrestrictedLadder.includes(model.id),
          state: this.stateOf(model.id),
        };
      });
    // Recommended first, then standard models, then the add-ons.
    const rank = (v: ModelView) => (v.recommended ? 0 : v.unrestricted ? 2 : 1);
    return views.sort((a, b) => rank(a) - rank(b));
  }

  stateOf(modelId: string): ModelState {
    return this.states.get(modelId) ?? NOT_INSTALLED;
  }

  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  // ---- start-up -----------------------------------------------------------

  async initialize(): Promise<void> {
    this.mutate(() => {
      this.phase = 'initializing';
    });
    if (this.options.catalogStore) {
      this.catalog = await this.options.catalogStore.load();
    }
    await this.loadPersisted();

    // A load that never finished means the app died in it.
    const crash = await this.journal.recoverFromCrash();
    if (crash && crash.kind.startsWith('cpu')) {
      // Even the CPU attempt killed the app: the model is too big here.
      await this.demote(crash.modelId, 'crashed');
    }

    const snapshot = await this.backend.readDevice();
    const device = classifyDevice(snapshot, this.catalog);
    this.mutate(() => {
      this.device = device;
    });
    this.reselect();
    await this.reconcileInstalled();
    this.mutate(() => {
      this.phase = 'ready';
    });
  }

  async getStarted(): Promise<void> {
    const device = this.requireDevice();
    const env = await this.environment([], false);
    const plan = planFirstRun(device, this.catalog, env, this.history());
    this.mutate(() => {
      this.selection = plan.selection;
    });
    if (plan.storageLimited) {
      this.notify({
        kind: 'storage_limited',
        needsAnswer: false,
        wantedModelId: plan.storageLimited.wanted.model.id,
        neededBytes: plan.storageLimited.neededBytes,
        freeBytes: plan.storageLimited.freeBytes,
      });
    }
    await this.startDownload(plan.selection.model.id, {thenLoad: true});
  }

  // ---- downloads ----------------------------------------------------------

  async download(
    modelId: string,
    options: {allowMetered?: boolean} = {},
  ): Promise<void> {
    await this.startDownload(modelId, {allowMetered: options.allowMetered});
  }

  pause(modelId: string): void {
    const active = this.downloads.get(modelId);
    if (
      active?.task &&
      this.dispatch(modelId, {type: 'DOWNLOAD_PAUSED', reason: 'user'})
    ) {
      active.task.pause();
    }
  }

  async resume(modelId: string): Promise<void> {
    const state = this.stateOf(modelId);
    if (state.status !== 'downloading' || !state.paused) {
      return;
    }
    const active = this.downloads.get(modelId);
    if (active?.task) {
      this.dispatch(modelId, {type: 'DOWNLOAD_RESUMED'});
      active.task.resume();
      return;
    }
    // Paused by losing the connection: there is no live task. Start again; the
    // backend continues from the bytes already on disk.
    await this.startDownload(modelId, {
      allowMetered: active?.allowMetered,
      thenLoad: active?.thenLoad,
    });
  }

  async cancel(modelId: string): Promise<void> {
    this.loadWhenInstalled.delete(modelId);
    const active = this.downloads.get(modelId);
    if (active) {
      active.cancelled = true;
      active.task?.cancel();
    }
    this.downloads.delete(modelId);
    if (this.dispatch(modelId, {type: 'DOWNLOAD_CANCELLED'})) {
      await this.removeFiles(modelId);
    }
  }

  async remove(modelId: string): Promise<void> {
    if (this.stateOf(modelId).status === 'downloading') {
      await this.cancel(modelId);
      return;
    }
    this.loadWhenInstalled.delete(modelId);
    if (this.context?.modelId === modelId) {
      await this.unload();
    }
    await this.removeFiles(modelId);
    this.dispatch(modelId, {type: 'REMOVED'});
  }

  async retry(modelId: string): Promise<void> {
    const state = this.stateOf(modelId);
    if (state.status !== 'failed') {
      return;
    }
    this.dispatch(modelId, {type: 'RETRY'});
    if (state.resumeTo === 'ready') {
      await this.load(modelId);
    } else {
      // A download that was meant to end in a load (first run, a fallback)
      // still is after the retry.
      await this.startDownload(modelId, {
        thenLoad: this.loadWhenInstalled.has(modelId),
      });
    }
  }

  private async startDownload(
    modelId: string,
    options: {allowMetered?: boolean; thenLoad?: boolean},
  ): Promise<void> {
    // A second tap while the first is still checking storage and network.
    if (this.starting.has(modelId)) {
      return;
    }
    if (options.thenLoad) {
      this.loadWhenInstalled.add(modelId);
    }
    this.starting.add(modelId);
    try {
      await this.runDownload(modelId, options);
    } finally {
      this.starting.delete(modelId);
    }
  }

  private async runDownload(
    modelId: string,
    options: {allowMetered?: boolean; thenLoad?: boolean},
  ): Promise<void> {
    const choice = this.choiceFor(modelId);
    const state = this.stateOf(modelId);
    // A download waiting for the connection has no live task and may restart.
    const waiting =
      state.status === 'downloading' && !this.downloads.get(modelId)?.task;
    if (!choice || (state.status === 'downloading' && !waiting)) {
      return;
    }
    if (state.status === 'failed') {
      this.dispatch(modelId, {type: 'RETRY'});
    }
    if (isInstalled(this.stateOf(modelId))) {
      if (options.thenLoad) {
        await this.load(modelId);
      }
      return;
    }

    const env = await this.environment(choice.files, options.allowMetered);
    const decision = decideDownload(choice.files, env, this.catalog.policy);
    switch (decision.kind) {
      case 'blocked':
        if (waiting && decision.reason === 'offline') {
          // Still offline: keep waiting.
          return;
        }
        this.downloads.delete(modelId);
        this.dispatch(modelId, {
          type: 'DOWNLOAD_FAILED',
          reason: decision.reason === 'offline' ? 'offline' : 'storage_full',
        });
        return;
      case 'confirm_metered':
        this.downloads.set(modelId, {
          task: null,
          cancelled: false,
          allowMetered: false,
          thenLoad: options.thenLoad ?? false,
        });
        this.notify({
          kind: 'confirm_metered',
          needsAnswer: true,
          modelId,
          bytes: decision.bytes,
        });
        return;
      case 'installed':
      case 'start':
        break;
    }

    const active: ActiveDownload = {
      task: null,
      cancelled: false,
      allowMetered: options.allowMetered ?? false,
      thenLoad: options.thenLoad ?? false,
    };
    this.downloads.set(modelId, active);
    const onDisk = new Map<CatalogFile, number>();
    for (const file of choice.files) {
      onDisk.set(file, Math.min(file.sizeBytes, env.bytesOnDisk(file)));
    }
    const received = () => [...onDisk.values()].reduce((sum, n) => sum + n, 0);
    if (waiting) {
      this.dispatch(modelId, {type: 'DOWNLOAD_RESUMED'});
    } else {
      this.dispatch(modelId, {
        type: 'DOWNLOAD_STARTED',
        totalBytes: choice.downloadBytes,
        receivedBytes: received(),
      });
    }

    try {
      // All files of the model start together. The native downloaders keep
      // going while the app is suspended, when no JS runs to start the next
      // file; a model with a projector would otherwise stop after the weights.
      const rates = new Map<CatalogFile, number>();
      const pending = choice.files.filter(
        file => (onDisk.get(file) as number) < file.sizeBytes,
      );
      active.task = combineDownloads(
        pending.map(file => {
          const task = this.backend.download(file, (bytes, rate) => {
            onDisk.set(file, Math.min(bytes, file.sizeBytes));
            if (rate !== undefined) {
              rates.set(file, rate);
            }
            this.dispatch(modelId, {
              type: 'DOWNLOAD_PROGRESS',
              receivedBytes: received(),
              bytesPerSecond:
                rates.size > 0
                  ? [...rates.values()].reduce((sum, n) => sum + n, 0)
                  : undefined,
            });
          });
          task.done.then(
            () => onDisk.set(file, file.sizeBytes),
            () => undefined,
          );
          return task;
        }),
      );
      await active.task.done;
    } catch (error) {
      active.task = null;
      if (active.cancelled) {
        return;
      }
      if (!this.backend.network().online) {
        // Not an error: the download waits for the connection.
        this.dispatch(modelId, {type: 'DOWNLOAD_PAUSED', reason: 'offline'});
        return;
      }
      // Online, and the transfer still broke (typically the error of a
      // dropped connection arriving after the connection is back). Carry on
      // from the bytes on disk by ourselves, a bounded number of times,
      // before asking the user to retry.
      const restarts = this.autoRestarts.get(modelId) ?? 0;
      if (restarts < MAX_AUTO_RESTARTS) {
        this.autoRestarts.set(modelId, restarts + 1);
        return this.runDownload(modelId, {
          allowMetered: active.allowMetered,
          thenLoad: active.thenLoad,
        });
      }
      this.autoRestarts.delete(modelId);
      this.downloads.delete(modelId);
      this.dispatch(modelId, {
        type: 'DOWNLOAD_FAILED',
        reason: 'download_failed',
        detail: messageOf(error),
      });
      return;
    }
    active.task = null;
    this.autoRestarts.delete(modelId);
    this.downloads.delete(modelId);
    this.dispatch(modelId, {type: 'DOWNLOAD_COMPLETED'});
    if ((await this.verifyFiles(modelId, choice.files)) && active.thenLoad) {
      // A download can end while the app is in the background. The model is
      // loaded when the user is back: iOS does not allow GPU work in the
      // background, and a background app holding gigabytes is the first to be
      // killed on either platform.
      await this.backend.waitUntilForeground?.();
      if (this.stateOf(modelId).status === 'ready') {
        await this.load(modelId);
      }
    }
  }

  /** Hash every file; a bad file is deleted so the retry downloads it again. */
  private async verifyFiles(
    modelId: string,
    files: CatalogFile[],
  ): Promise<boolean> {
    const total = files.reduce((sum, f) => sum + f.sizeBytes, 0);
    let before = 0;
    for (const file of files) {
      let ok = false;
      let detail: string | undefined;
      try {
        const offset = before;
        ok = await this.backend.verify(file, fraction =>
          this.dispatch(modelId, {
            type: 'VERIFY_PROGRESS',
            fraction: (offset + fraction * file.sizeBytes) / total,
          }),
        );
      } catch (error) {
        detail = messageOf(error);
      }
      if (!ok) {
        await this.backend.remove(file).catch(() => undefined);
        this.dispatch(modelId, {
          type: 'VERIFY_FAILED',
          detail: detail ?? `${file.path} does not match its checksum`,
        });
        return false;
      }
      before += file.sizeBytes;
    }
    this.dispatch(modelId, {type: 'VERIFY_PASSED'});
    return true;
  }

  // ---- loading ------------------------------------------------------------

  async load(modelId: string): Promise<void> {
    const device = this.requireDevice();
    const choice = this.choiceFor(modelId);
    if (!choice) {
      return;
    }
    if (this.stateOf(modelId).status === 'failed') {
      this.dispatch(modelId, {type: 'RETRY'});
    }
    if (this.stateOf(modelId).status !== 'ready') {
      return;
    }
    if (this.context) {
      await this.unload();
    }
    this.loadWhenInstalled.delete(modelId);
    this.dispatch(modelId, {type: 'LOAD_STARTED'});
    this.mutate(() => {
      this.activeModelId = modelId;
    });

    const {policy} = this.catalog;
    const availableBytes = await this.backend
      .availableMemoryBytes?.()
      .catch(() => undefined);
    const attempts = planInitAttempts(
      device,
      choice.model,
      choice.shape,
      policy,
      {
        availableBytes,
        crashed: await this.journal.crashedKinds(modelId),
      },
    );
    const weights = weightsFor(choice.model, choice.shape.backend);

    try {
      const result = await runInitChain<C>({
        attempts,
        journal: this.journal,
        modelId,
        init: attempt =>
          this.backend.initContext({
            model: choice.model,
            weights,
            projector: attempt.vision ? choice.model.projector : undefined,
            attempt,
          }),
        release: context => this.backend.releaseContext(context),
        onAttempt: (attempt, index, total) =>
          this.dispatch(modelId, {
            type: 'LOAD_ATTEMPT',
            index,
            total,
            kind: attempt.kind,
          }),
      });
      this.context = {modelId, handle: result.context, choice};
      const known = this.persisted.calibration[modelId];
      this.meter = known
        ? null
        : new SpeedMeter(policy.calibrationSeconds, this.now);
      this.dispatch(modelId, {
        type: 'LOAD_SUCCEEDED',
        info: {
          backend: result.attempt.backend,
          gpuLayers: result.attempt.gpuLayers,
          contextSize: result.attempt.contextSize,
          vision: result.attempt.vision,
          attempt: result.attempt.kind,
          degraded: result.failures.length > 0,
          tokensPerSecond: known?.tokensPerSecond,
        },
      });
    } catch (error) {
      const reason: FailureReason =
        error instanceof InitChainError && error.reason === 'out_of_memory'
          ? 'out_of_memory'
          : 'load_failed';
      this.dispatch(modelId, {
        type: 'LOAD_FAILED',
        reason,
        detail: messageOf(error),
      });
      this.mutate(() => {
        this.activeModelId = null;
      });
      await this.fallBackFrom(modelId);
    }
  }

  /** Last link of the fallback chain: the next smaller model. */
  private async fallBackFrom(modelId: string): Promise<void> {
    const model = getModel(this.catalog, modelId);
    const smaller = stepDown(this.catalog, modelId);
    // Only the automatic choice falls back by itself; a model the user picked
    // by hand just shows its failure.
    if (!model || smaller === null || modelId !== this.recommendedModelId) {
      return;
    }
    await this.demote(modelId, 'load_failed');
    const next = this.recommendedModelId;
    if (next === null || next === modelId) {
      return;
    }
    this.notify({
      kind: 'load_fell_back',
      needsAnswer: false,
      from: modelId,
      to: next,
    });
    await this.startDownload(next, {thenLoad: true});
  }

  async unload(): Promise<void> {
    const context = this.context;
    if (!context) {
      return;
    }
    this.context = null;
    this.meter = null;
    this.releaseWhenIdle = false;
    await this.backend.releaseContext(context.handle).catch(() => undefined);
    this.dispatch(context.modelId, {type: 'UNLOADED'});
    this.mutate(() => {
      this.activeModelId = null;
    });
  }

  // ---- calibration and memory pressure ------------------------------------

  noteGeneratedTokens(count: number): void {
    const meter = this.meter;
    const context = this.context;
    if (!meter || !context) {
      return;
    }
    meter.onTokens(count);
    if (!meter.done) {
      return;
    }
    this.meter = null;
    const verdict = judgeCalibration(
      meter.sample(),
      context.modelId,
      this.catalog,
      this.persisted.calibration[context.modelId],
    );
    if (verdict.verdict === 'inconclusive') {
      return;
    }
    this.dispatch(context.modelId, {
      type: 'SPEED_MEASURED',
      tokensPerSecond: verdict.tokensPerSecond,
    });
    const offer = verdict.verdict === 'too_slow' ? verdict.offerModelId : null;
    this.persisted.calibration[context.modelId] = {
      tokensPerSecond: verdict.tokensPerSecond,
      slowOfferShown:
        this.persisted.calibration[context.modelId]?.slowOfferShown ||
        offer !== null,
    };
    this.savePersisted();
    if (offer !== null) {
      this.notify({
        kind: 'slow_offer_smaller',
        needsAnswer: true,
        modelId: context.modelId,
        offerModelId: offer,
        tokensPerSecond: verdict.tokensPerSecond,
      });
    }
  }

  async noteGenerationFinished(): Promise<void> {
    this.meter?.endSegment();
    if (this.releaseWhenIdle) {
      await this.unload();
    }
  }

  async onMemoryPressure(
    level: MemoryPressure,
    pressure: PressureContext,
  ): Promise<void> {
    const loaded = this.context;
    const loadedState = loaded ? this.stateOf(loaded.modelId) : null;
    const actions = reactToLowMemory(
      {
        level,
        loadedModelId: loaded?.modelId ?? null,
        projectorLoaded:
          loadedState?.status === 'loaded' && loadedState.info.vision,
        generating: pressure.generating,
        aux: pressure.aux,
        recentReleases: this.recentReleases,
        now: this.now(),
      },
      this.catalog,
    );
    for (const step of actions) {
      switch (step.type) {
        case 'release_aux':
          await this.backend.releaseAux?.(step.which).catch(() => undefined);
          break;
        case 'release_projector':
          if (loaded) {
            await this.backend
              .releaseProjector?.(loaded.handle)
              .catch(() => undefined);
          }
          break;
        case 'release_model':
          this.recentReleases = [...this.recentReleases, this.now()].slice(-4);
          if (step.when === 'now') {
            await this.unload();
          } else {
            this.releaseWhenIdle = true;
          }
          break;
        case 'demote':
          await this.demote(step.from, 'low_memory');
          this.notify({
            kind: 'low_memory_switched',
            needsAnswer: false,
            from: step.from,
            to: this.recommendedModelId ?? step.to,
          });
          break;
      }
    }
  }

  async onNetworkChange(): Promise<void> {
    const network = this.backend.network();
    for (const [modelId, active] of [...this.downloads]) {
      const state = this.stateOf(modelId);
      if (state.status !== 'downloading') {
        continue;
      }
      const waiting = state.paused && state.pauseReason !== 'user';
      if (!network.online && !state.paused && active.task) {
        // The native downloaders do not fail when the connection goes; they
        // wait and retry. The state should say what the user sees: waiting
        // for a connection.
        this.dispatch(modelId, {type: 'DOWNLOAD_PAUSED', reason: 'offline'});
        active.task.pause();
        continue;
      }
      if (
        network.online &&
        waiting &&
        (!network.metered || active.allowMetered)
      ) {
        await this.resume(modelId);
      } else if (
        !state.paused &&
        active.task &&
        network.online &&
        network.metered &&
        !active.allowMetered
      ) {
        // Wi-Fi dropped to cellular mid-download: stop spending data.
        this.dispatch(modelId, {type: 'DOWNLOAD_PAUSED', reason: 'metered'});
        active.task.pause();
      }
    }
  }

  // ---- notices ------------------------------------------------------------

  async answerNotice(noticeId: string, accept: boolean): Promise<void> {
    const notice = this.notices.find(n => n.id === noticeId);
    if (!notice) {
      return;
    }
    this.dismissNotice(noticeId);
    if (notice.kind === 'confirm_metered') {
      const pending = this.downloads.get(notice.modelId);
      this.downloads.delete(notice.modelId);
      if (accept) {
        await this.startDownload(notice.modelId, {
          allowMetered: true,
          thenLoad: pending?.thenLoad,
        });
      }
    } else if (notice.kind === 'slow_offer_smaller' && accept) {
      await this.demote(notice.modelId, 'too_slow');
      const next = this.recommendedModelId ?? notice.offerModelId;
      await this.startDownload(next, {thenLoad: true});
    }
  }

  dismissNotice(noticeId: string): void {
    this.notices = this.notices.filter(n => n.id !== noticeId);
    this.emit();
  }

  // ---- internals ----------------------------------------------------------

  private requireDevice(): DeviceProfile {
    if (!this.device) {
      throw new Error('ModelEngine.initialize() has not completed');
    }
    return this.device;
  }

  private history() {
    return {demoted: this.persisted.demoted};
  }

  private reselect(): void {
    const device = this.requireDevice();
    const selection = selectModel(device, this.catalog, this.history());
    const unrestricted = selectUnrestricted(
      device,
      this.catalog,
      this.history(),
    );
    this.mutate(() => {
      this.selection = selection;
      this.unrestrictedChoice = unrestricted;
    });
  }

  /** How a model would be loaded on this phone; null if it cannot run here. */
  private choiceFor(modelId: string): ModelChoice | null {
    const device = this.device;
    if (!device) {
      return null;
    }
    if (this.selection?.model.id === modelId) {
      return this.selection;
    }
    if (this.unrestrictedChoice?.model.id === modelId) {
      return this.unrestrictedChoice;
    }
    const model = getModel(this.catalog, modelId);
    if (!model || isRevoked(this.catalog, model)) {
      return null;
    }
    const wantVision = getClass(this.catalog, device.deviceClass).features
      .vision;
    return bestShapeFor(model, device, this.catalog, wantVision);
  }

  private async demote(modelId: string, reason: DemotionReason): Promise<void> {
    this.persisted.demoted[modelId] = reason;
    this.savePersisted();
    if (this.device) {
      this.reselect();
    }
  }

  private async reconcileInstalled(): Promise<void> {
    for (const model of this.catalog.models) {
      const choice = this.choiceFor(model.id);
      // A model too large for this phone may still be on it (an older
      // reading, a restored backup): look for its weights so the store can
      // show it as installed.
      const files =
        choice?.files ??
        (this.device ? filesFor(model, this.device.gpu.backend, false) : []);
      if (files.length === 0) {
        continue;
      }
      const verified = await Promise.all(
        files.map(file => this.backend.isVerified(file).catch(() => false)),
      );
      if (verified.every(Boolean)) {
        this.dispatch(model.id, {type: 'FOUND_ON_DISK'});
      }
    }
  }

  private async removeFiles(modelId: string): Promise<void> {
    const model = getModel(this.catalog, modelId);
    if (!model) {
      return;
    }
    const files: CatalogFile[] = [...model.files];
    if (model.projector) {
      files.push(model.projector);
    }
    await Promise.all(
      files.map(file => this.backend.remove(file).catch(() => undefined)),
    );
  }

  private async environment(files: CatalogFile[], allowMetered?: boolean) {
    const sizes = new Map<CatalogFile, number>();
    await Promise.all(
      files.map(async file => {
        sizes.set(file, await this.backend.bytesOnDisk(file).catch(() => 0));
      }),
    );
    return {
      network: this.backend.network(),
      freeStorageBytes: await this.backend.freeStorageBytes().catch(() => null),
      bytesOnDisk: (file: CatalogFile) => sizes.get(file) ?? 0,
      allowMetered,
    };
  }

  private async loadPersisted(): Promise<void> {
    try {
      const raw = await this.storage.getItem(HISTORY_KEY);
      if (raw !== null) {
        const saved = JSON.parse(raw) as Partial<Persisted>;
        this.persisted = {
          demoted: saved.demoted ?? {},
          calibration: saved.calibration ?? {},
        };
      }
    } catch {
      this.persisted = {demoted: {}, calibration: {}};
    }
  }

  private savePersisted(): void {
    this.storage
      .setItem(HISTORY_KEY, JSON.stringify(this.persisted))
      .catch(() => undefined);
  }

  private notify(notice: DistributiveOmit<ModelNotice, 'id'>): void {
    const id = `notice-${++this.noticeCounter}`;
    this.mutate(() => {
      this.notices = [...this.notices, {...notice, id} as ModelNotice];
    });
  }

  /** Apply an event; returns whether the state changed. */
  private dispatch(modelId: string, event: ModelEvent): boolean {
    const before = this.stateOf(modelId);
    const after = transition(before, event);
    if (after === before) {
      return false;
    }
    this.mutate(() => {
      this.states.set(modelId, after);
    });
    return true;
  }

  private mutate(change: () => void): void {
    runInAction(change);
    this.emit();
  }

  private emit(): void {
    this.listeners.forEach(listener => listener());
  }
}

/**
 * Several file downloads as one task. When one fails the others are stopped
 * too; their bytes stay on disk for the retry.
 */
function combineDownloads(tasks: DownloadTask[]): DownloadTask {
  let stopped = false;
  const done = Promise.all(
    tasks.map(task =>
      task.done.catch(error => {
        if (!stopped) {
          stopped = true;
          // `cancel` stops a task and keeps its partial data (see DownloadTask).
          for (const other of tasks) {
            if (other !== task) {
              try {
                other.cancel();
              } catch {
                // Already settled: nothing to stop.
              }
            }
          }
        }
        throw error;
      }),
    ),
  ).then(() => undefined);
  return {
    done,
    pause: () => tasks.forEach(task => task.pause()),
    resume: () => tasks.forEach(task => task.resume()),
    cancel: () => {
      stopped = true;
      tasks.forEach(task => task.cancel());
    },
  };
}

type DistributiveOmit<T, K extends keyof any> = T extends unknown
  ? Omit<T, K>
  : never;

const messageOf = (error: unknown): string =>
  error instanceof Error ? error.message : String(error);
