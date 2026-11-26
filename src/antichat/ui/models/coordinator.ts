/**
 * Keeps a model loaded without the user ever being asked to manage one.
 *
 * The engine (M5) knows how to download, verify and load. This decides WHEN:
 * at first run, after a restart, when the connection changes, after a model
 * was deleted, when the user picks another one. It talks to `ModelPort` and
 * `Connectivity` only, so it is the same code on the scripted and the real
 * backend.
 */
import {makeAutoObservable, runInAction} from 'mobx';

import type {Connectivity, ModelPort, ModelView} from '../../contracts';
import {ModelPrefs} from './modelPrefs';
import {isInstalled, lineup} from './naming';
import {setupStatus, type SetupStatus} from './setupStatus';

export interface CoordinatorOptions {
  model: ModelPort;
  connectivity: Connectivity;
  prefs?: ModelPrefs;
  /** Starts the runtime; defaults to `model.initialize()`. */
  start?: () => Promise<void>;
  /** Free space on the phone, for "free up 2.1 GB". */
  freeStorageBytes?: () => Promise<number>;
  /** Called once when the first model becomes usable. */
  onReady?: (model: ModelView) => void;
}

export class ModelCoordinator {
  readonly prefs: ModelPrefs;
  booted = false;
  /** A start was requested and the engine has not reported a state yet. */
  kickingOff = false;
  /** The ready moment is on screen. */
  celebrating = false;
  /** Bumped when a new free-space reading arrives. */
  freeVersion = 0;

  private readonly model: ModelPort;
  private readonly connectivity: Connectivity;
  private readonly startRuntime: () => Promise<void>;
  private readonly onReady?: (model: ModelView) => void;
  private booting: Promise<void> | null = null;
  private loadingId: string | null = null;
  private pendingSwitch: string | null = null;
  private readonly removing = new Set<string>();
  private unsubscribe: Array<() => void> = [];
  private celebrateTimer: ReturnType<typeof setTimeout> | null = null;
  /** Free space as last read; refreshed when a download fails for space. */
  private freeBytes: number | undefined;
  private readFree: (() => Promise<number>) | undefined;
  private readingFree = false;

  constructor(options: CoordinatorOptions) {
    this.model = options.model;
    this.connectivity = options.connectivity;
    this.prefs = options.prefs ?? new ModelPrefs();
    this.onReady = options.onReady;
    this.readFree = options.freeStorageBytes;
    this.startRuntime =
      options.start ??
      (() =>
        this.model.phase === 'idle'
          ? this.model.initialize()
          : Promise.resolve());
    makeAutoObservable<
      ModelCoordinator,
      | 'model'
      | 'connectivity'
      | 'startRuntime'
      | 'onReady'
      | 'booting'
      | 'loadingId'
      | 'pendingSwitch'
      | 'removing'
      | 'unsubscribe'
      | 'celebrateTimer'
      | 'freeBytes'
      | 'readFree'
      | 'readingFree'
    >(this, {
      prefs: false,
      model: false,
      connectivity: false,
      startRuntime: false,
      onReady: false,
      booting: false,
      loadingId: false,
      pendingSwitch: false,
      removing: false,
      unsubscribe: false,
      celebrateTimer: false,
      freeBytes: false,
      readFree: false,
      readingFree: false,
    });
  }

  /** Load what was stored, start the engine, continue where the app left off. */
  boot(): Promise<void> {
    this.booting ??= (async () => {
      await this.prefs.load();
      this.unsubscribe.push(
        this.model.subscribe(() => this.react()),
        this.connectivity.subscribe(() => this.onConnectivity()),
      );
      try {
        await this.startRuntime();
      } finally {
        runInAction(() => {
          this.booted = true;
        });
      }
      if (this.prefs.started) {
        this.ensure();
      }
    })();
    return this.booting;
  }

  dispose(): void {
    this.unsubscribe.splice(0).forEach(off => off());
    if (this.celebrateTimer) {
      clearTimeout(this.celebrateTimer);
    }
    this.booting = null;
  }

  // ---- reads ----------------------------------------------------------------

  /** The model the app should be running: the user's choice, or its own. */
  get targetId(): string | null {
    const {selection} = this.prefs;
    if (selection !== 'auto') {
      const chosen = this.model.models.find(model => model.id === selection);
      if (chosen?.supported) {
        return chosen.id;
      }
    }
    return this.model.recommendedModelId;
  }

  target(): ModelView | undefined {
    const id = this.targetId;
    return this.model.models.find(model => model.id === id);
  }

  /** What the first-run card shows right now. */
  status(): SetupStatus {
    const target = this.target();
    const active = this.model.activeModelId;
    const status = setupStatus({
      started: this.prefs.started,
      enginePhase: this.model.phase,
      targetId: target?.id ?? null,
      targetBytes: target?.downloadBytes ?? 0,
      state: target?.state ?? {status: 'not_installed'},
      activeModelId: active,
      activeState: active ? this.model.stateOf(active) : undefined,
      notices: this.model.notices,
      waitForWifi: this.prefs.waitForWifi,
      celebrate: this.celebrating,
      freeBytes: this.freeBytes,
    });
    if (status.kind === 'missing' && (this.kickingOff || !this.booted)) {
      return {kind: 'preparing'};
    }
    return status;
  }

  get chatReady(): boolean {
    const active = this.model.activeModelId;
    return active !== null && this.model.stateOf(active).status === 'loaded';
  }

  // ---- commands -------------------------------------------------------------

  /** The one decision of first run. */
  getStarted(): void {
    this.prefs.set({started: true});
    this.ensure();
  }

  /** Make sure the target model is on its way to being loaded. */
  ensure(): void {
    if (this.model.phase !== 'ready') {
      return;
    }
    const target = this.target();
    if (!target) {
      return;
    }
    if (isInstalled(target)) {
      this.loadIfIdle(target.id);
      return;
    }
    // Something else is installed: use it. The app never downloads behind
    // the back of a user who has a working model.
    const fallback = this.installedFallback();
    if (fallback) {
      this.loadIfIdle(fallback.id);
      return;
    }
    if (target.state.status !== 'not_installed' || this.prefs.holdDownload) {
      return;
    }
    if (this.prefs.waitForWifi && this.connectivity.metered) {
      return;
    }
    this.kick(
      this.prefs.automatic
        ? this.model.getStarted()
        : this.model.download(target.id),
    );
  }

  pause(): void {
    const target = this.target();
    if (target) {
      this.prefs.set({userPaused: true});
      this.model.pause(target.id);
    }
  }

  resume(): void {
    const target = this.target();
    if (!target) {
      return;
    }
    this.prefs.set({userPaused: false, holdDownload: false});
    if (target.state.status === 'downloading' && target.state.paused) {
      this.model.resume(target.id).catch(() => undefined);
    } else {
      this.ensure();
    }
  }

  retry(): void {
    const target = this.target();
    if (!target) {
      return;
    }
    this.prefs.set({holdDownload: false});
    if (target.state.status === 'failed') {
      this.kick(this.model.retry(target.id));
    } else {
      this.ensure();
    }
  }

  /** Answer to "use mobile data?". */
  useMobileData(): void {
    this.prefs.set({waitForWifi: false, holdDownload: false});
    const target = this.target();
    const notice = this.model.notices.find(
      item => item.kind === 'confirm_metered' && item.modelId === target?.id,
    );
    if (notice) {
      this.kick(this.model.answerNotice(notice.id, true));
    } else if (target) {
      this.kick(this.model.download(target.id, {allowMetered: true}));
    }
  }

  waitForWifi(): void {
    this.prefs.set({waitForWifi: true});
    this.model.notices
      .filter(item => item.kind === 'confirm_metered')
      .forEach(item => {
        this.model.answerNotice(item.id, false).catch(() => undefined);
      });
  }

  /**
   * Use this model from now on; `auto` hands the choice back to the app. A
   * model that is not on the phone yet is downloaded and then switched to.
   */
  choose(selection: string): void {
    this.prefs.set({selection, userPaused: false});
    const target = this.target();
    if (!target) {
      return;
    }
    if (isInstalled(target)) {
      this.pendingSwitch = null;
      if (this.model.activeModelId !== target.id) {
        this.load(target.id);
      }
      return;
    }
    this.pendingSwitch = target.id;
    if (target.state.status === 'not_installed') {
      this.download(target.id);
    }
  }

  /** Download a model the user asked for by hand (Manage models). */
  download(modelId: string, options?: {allowMetered?: boolean}): void {
    this.prefs.set({holdDownload: false, userPaused: false});
    this.kick(this.model.download(modelId, options));
  }

  /**
   * Delete a model. If it was in use, another installed one takes over; if it
   * was the last one, nothing is downloaded again until the user asks.
   */
  async remove(modelId: string): Promise<void> {
    const wasTarget = this.targetId === modelId;
    // Unloading makes the model look idle for a moment; it must not be
    // loaded again while its files are being deleted.
    this.removing.add(modelId);
    if (this.pendingSwitch === modelId) {
      this.pendingSwitch = null;
    }
    try {
      await this.model.remove(modelId);
    } finally {
      this.removing.delete(modelId);
    }
    if (wasTarget) {
      const fallback = this.installedFallback();
      this.prefs.set({
        selection: fallback ? fallback.id : 'auto',
        holdDownload: !fallback,
        userPaused: false,
      });
    }
    this.react();
  }

  endCelebration(): void {
    if (this.celebrateTimer) {
      clearTimeout(this.celebrateTimer);
      this.celebrateTimer = null;
    }
    this.celebrating = false;
  }

  // ---- internals ------------------------------------------------------------

  private kick(work: Promise<void>): void {
    this.kickingOff = true;
    const settle = () =>
      runInAction(() => {
        this.kickingOff = false;
      });
    // The engine publishes a state long before these promises settle (a
    // first run resolves only when the model is loaded).
    const off = this.model.subscribe(() => {
      off();
      settle();
    });
    work
      .catch(() => undefined)
      .finally(() => {
        off();
        settle();
      });
  }

  private loadIfIdle(modelId: string): void {
    const active = this.model.activeModelId;
    if (active !== null || this.loadingId !== null) {
      return;
    }
    if (this.model.stateOf(modelId).status !== 'ready') {
      return;
    }
    this.load(modelId);
  }

  private load(modelId: string): void {
    this.loadingId = modelId;
    this.model
      .load(modelId)
      .catch(() => undefined)
      .finally(() => {
        this.loadingId = null;
      });
  }

  private installedFallback(): ModelView | undefined {
    const installed = this.model.models.filter(
      model =>
        model.supported && isInstalled(model) && !this.removing.has(model.id),
    );
    const models = lineup(this.model);
    return (
      installed.find(model => model.id === models.smart?.id) ??
      installed.find(model => !model.unrestricted) ??
      installed[0]
    );
  }

  /** The engine changed: keep a model loaded, notice the first "ready". */
  private react(): void {
    if (!this.prefs.started || this.model.phase !== 'ready') {
      return;
    }
    const active = this.model.activeModelId;
    const target = this.target();
    this.freeBytes ??= this.model.device?.snapshot.freeStorageBytes;
    if (
      target?.state.status === 'failed' &&
      target.state.reason === 'storage_full' &&
      this.readFree &&
      !this.readingFree
    ) {
      this.readingFree = true;
      this.readFree()
        .then(free => {
          const changed = free !== this.freeBytes;
          this.freeBytes = free;
          if (changed) {
            runInAction(() => {
              this.freeVersion += 1;
            });
          }
        })
        .catch(() => undefined)
        .finally(() => {
          this.readingFree = false;
        });
    }

    // A download that the user had paused stays paused after a restart.
    if (
      this.prefs.userPaused &&
      target?.state.status === 'downloading' &&
      !target.state.paused
    ) {
      this.model.pause(target.id);
      return;
    }

    if (
      this.pendingSwitch !== null &&
      this.loadingId === null &&
      this.model.stateOf(this.pendingSwitch).status === 'ready'
    ) {
      const next = this.pendingSwitch;
      this.pendingSwitch = null;
      this.load(next);
      return;
    }

    if (active === null && this.loadingId === null) {
      const next =
        target && isInstalled(target) && !this.removing.has(target.id)
          ? target
          : this.installedFallback();
      if (next && next.state.status === 'ready') {
        this.load(next.id);
      }
    }

    if (
      active !== null &&
      !this.prefs.celebrated &&
      this.model.stateOf(active).status === 'loaded'
    ) {
      this.prefs.set({celebrated: true, waitForWifi: false});
      runInAction(() => {
        this.celebrating = true;
      });
      const view = this.model.models.find(model => model.id === active);
      if (view) {
        this.onReady?.(view);
      }
      this.celebrateTimer = setTimeout(() => this.endCelebration(), 6000);
    }
  }

  private onConnectivity(): void {
    if (!this.prefs.started || this.model.phase !== 'ready') {
      return;
    }
    const target = this.target();
    if (
      target?.state.status === 'not_installed' &&
      this.connectivity.online &&
      !this.connectivity.metered &&
      this.model.activeModelId === null
    ) {
      // Wi-Fi is back: the waiting download starts by itself.
      this.ensure();
    }
  }
}
