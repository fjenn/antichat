import {Emitter} from '../common';
import type {
  CapabilityMap,
  DeviceClass,
  DeviceProfile,
  EnginePhase,
  MemoryPressure,
  ModelNotice,
  ModelPort,
  ModelState,
  ModelView,
  PressureContext,
} from '../model';

const GB = 1024 * 1024 * 1024;

type Catalogued = Omit<ModelView, 'state'>;

const CATALOG: Catalogued[] = [
  {
    id: 'fake-small',
    displayName: 'AntiChat',
    downloadBytes: 2.1 * GB,
    unrestricted: false,
    licenceName: 'Apache-2.0',
    openSource: true,
    recommended: true,
    supported: true,
    vision: true,
  },
  {
    id: 'fake-large',
    displayName: 'AntiChat Large',
    downloadBytes: 5.4 * GB,
    unrestricted: false,
    licenceName: 'Apache-2.0',
    openSource: true,
    recommended: false,
    supported: true,
    vision: true,
  },
  {
    id: 'fake-open',
    displayName: 'AntiChat Unrestricted',
    downloadBytes: 2.3 * GB,
    unrestricted: true,
    licenceName: 'Gemma Terms',
    openSource: false,
    licenceNotice: 'Source-available licence.',
    recommended: false,
    supported: true,
    vision: false,
  },
];

const yes = {available: true} as const;

export interface FakeModelOptions {
  /** Start as a fresh install: nothing downloaded. */
  fresh?: boolean;
  deviceClass?: DeviceClass;
  /** Simulated download speed. */
  bytesPerSecond?: number;
  loadMs?: number;
}

/**
 * A model engine with believable timing: downloads tick, loads take a moment,
 * failures and notices can be injected. Starts with the recommended model
 * loaded unless `fresh`.
 */
export class FakeModel extends Emitter implements ModelPort {
  phase: EnginePhase = 'idle';
  device: DeviceProfile | null = null;
  deviceClass: DeviceClass | null = null;
  capabilities: CapabilityMap | null = null;
  models: ModelView[] = [];
  recommendedModelId: string | null = 'fake-small';
  unrestrictedModelId: string | null = 'fake-open';
  activeModelId: string | null = null;
  notices: ModelNotice[] = [];
  /** Tokens reported by chat, for tests. */
  generatedTokens = 0;

  private readonly states = new Map<string, ModelState>();
  private readonly timers = new Map<string, ReturnType<typeof setInterval>>();
  private readonly options: Required<FakeModelOptions>;

  constructor(options: FakeModelOptions = {}) {
    super();
    this.options = {
      fresh: false,
      deviceClass: 'C',
      bytesPerSecond: 0.4 * GB,
      loadMs: 900,
      ...options,
    };
    CATALOG.forEach(model =>
      this.states.set(model.id, {status: 'not_installed'}),
    );
    if (!this.options.fresh) {
      this.states.set('fake-small', {
        status: 'loaded',
        info: {
          backend: 'metal',
          gpuLayers: 99,
          contextSize: 8192,
          vision: true,
          attempt: 'gpu',
          degraded: false,
          tokensPerSecond: 38,
        },
      });
      this.states.set('fake-large', {status: 'ready'});
      this.activeModelId = 'fake-small';
      this.phase = 'ready';
      this.deviceClass = this.options.deviceClass;
      this.capabilities = this.buildCapabilities('fake-small');
    }
    this.refresh(false);
  }

  stateOf(modelId: string): ModelState {
    return this.states.get(modelId) ?? {status: 'not_installed'};
  }

  async initialize(): Promise<void> {
    this.phase = 'initializing';
    this.refresh();
    await delay(50);
    this.phase = 'ready';
    this.deviceClass = this.options.deviceClass;
    this.capabilities = this.buildCapabilities(
      this.activeModelId ?? 'fake-small',
    );
    this.refresh();
  }

  async getStarted(): Promise<void> {
    await this.download('fake-small');
    await this.load('fake-small');
  }

  download(modelId: string): Promise<void> {
    const total = this.view(modelId).downloadBytes;
    const current = this.stateOf(modelId);
    const received =
      current.status === 'downloading' ? current.progress.receivedBytes : 0;
    return this.runDownload(modelId, received, total);
  }

  pause(modelId: string): void {
    const state = this.stateOf(modelId);
    if (state.status === 'downloading') {
      this.stopTimer(modelId);
      this.set(modelId, {...state, paused: true, pauseReason: 'user'});
    }
  }

  resume(modelId: string): Promise<void> {
    return this.download(modelId);
  }

  async cancel(modelId: string): Promise<void> {
    this.stopTimer(modelId);
    this.set(modelId, {status: 'not_installed'});
  }

  async remove(modelId: string): Promise<void> {
    this.stopTimer(modelId);
    if (this.activeModelId === modelId) {
      this.activeModelId = null;
    }
    this.set(modelId, {status: 'not_installed'});
  }

  async load(modelId: string): Promise<void> {
    if (this.activeModelId && this.activeModelId !== modelId) {
      this.set(this.activeModelId, {status: 'ready'});
    }
    this.activeModelId = modelId;
    this.set(modelId, {
      status: 'loading',
      attempt: {index: 0, total: 3, kind: 'gpu'},
    });
    await delay(this.options.loadMs);
    this.set(modelId, {
      status: 'loaded',
      info: {
        backend: 'metal',
        gpuLayers: 99,
        contextSize: 8192,
        vision: this.view(modelId).vision,
        attempt: 'gpu',
        degraded: false,
      },
    });
    this.capabilities = this.buildCapabilities(modelId);
    this.refresh();
  }

  async unload(): Promise<void> {
    if (this.activeModelId) {
      const id = this.activeModelId;
      this.activeModelId = null;
      this.set(id, {status: 'ready'});
    }
  }

  async retry(modelId: string): Promise<void> {
    const state = this.stateOf(modelId);
    if (state.status !== 'failed') {
      return;
    }
    if (state.resumeTo === 'ready') {
      await this.load(modelId);
    } else {
      await this.download(modelId);
    }
  }

  async answerNotice(noticeId: string, accept: boolean): Promise<void> {
    const notice = this.notices.find(item => item.id === noticeId);
    this.dismissNotice(noticeId);
    if (accept && notice?.kind === 'slow_offer_smaller') {
      await this.load(notice.offerModelId);
    }
  }

  dismissNotice(noticeId: string): void {
    this.notices = this.notices.filter(notice => notice.id !== noticeId);
    this.refresh();
  }

  noteGeneratedTokens(count: number): void {
    this.generatedTokens += count;
  }

  async noteGenerationFinished(): Promise<void> {}

  async onMemoryPressure(
    level: MemoryPressure,
    _context: PressureContext,
  ): Promise<void> {
    if (level === 'critical' && this.activeModelId === 'fake-large') {
      await this.load('fake-small');
      this.pushNotice({
        id: `n${Date.now()}`,
        kind: 'low_memory_switched',
        needsAnswer: false,
        from: 'fake-large',
        to: 'fake-small',
      });
    }
  }

  async onNetworkChange(): Promise<void> {}

  /** Test and demo control: put a model into any state. */
  setState(modelId: string, state: ModelState): void {
    this.set(modelId, state);
  }

  /** Test and demo control: show a notice. */
  pushNotice(notice: ModelNotice): void {
    this.notices = [...this.notices, notice];
    this.refresh();
  }

  private runDownload(
    modelId: string,
    startAt: number,
    total: number,
  ): Promise<void> {
    this.stopTimer(modelId);
    const stepMs = 100;
    const perStep = (this.options.bytesPerSecond * stepMs) / 1000;
    let received = startAt;
    return new Promise(resolve => {
      const publish = () =>
        this.set(modelId, {
          status: 'downloading',
          paused: false,
          progress: {
            receivedBytes: received,
            totalBytes: total,
            fraction: received / total,
            bytesPerSecond: this.options.bytesPerSecond,
            etaSeconds: (total - received) / this.options.bytesPerSecond,
          },
        });
      publish();
      const timer = setInterval(() => {
        received = Math.min(total, received + perStep);
        if (received < total) {
          publish();
          return;
        }
        this.stopTimer(modelId);
        this.set(modelId, {status: 'verifying', fraction: 1});
        this.set(modelId, {status: 'ready'});
        resolve();
      }, stepMs);
      this.timers.set(modelId, timer);
    });
  }

  private stopTimer(modelId: string): void {
    clearInterval(this.timers.get(modelId));
    this.timers.delete(modelId);
  }

  private view(modelId: string): Catalogued {
    const found = CATALOG.find(model => model.id === modelId);
    if (!found) {
      throw new Error(`Unknown model ${modelId}`);
    }
    return found;
  }

  private set(modelId: string, state: ModelState): void {
    this.states.set(modelId, state);
    this.refresh();
  }

  private refresh(notify = true): void {
    this.models = CATALOG.map(model => ({
      ...model,
      state: this.stateOf(model.id),
    }));
    if (notify) {
      this.emit();
    }
  }

  private buildCapabilities(modelId: string): CapabilityMap {
    const vision = this.view(modelId).vision;
    return {
      deviceClass: this.options.deviceClass,
      modelId,
      contextSize: 8192,
      vision: vision ? yes : {available: false, reason: {kind: 'model_lacks'}},
      imageInput: vision ? 'model' : 'ocr',
      audioInput: {available: false, reason: {kind: 'model_lacks'}},
      imageGeneration: yes,
      voiceMode: yes,
      embeddings: yes,
      research: yes,
      followUps: yes,
      renderHtml: yes,
      backgroundMemory: yes,
      tools: yes,
      thinking: yes,
      thinkingAlwaysOn: false,
      searchQueriesPerTurn: 3,
      maxTools: 8,
    };
  }
}

function delay(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}
