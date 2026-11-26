/**
 * ModelPort: everything the UI needs from the model engine.
 *
 * The shapes are those of the M5 draft (`engine/models/port.ts` and the
 * types it imports). When M5 merges, its files import these instead of
 * declaring their own. The UI reads the observable fields and calls the
 * commands; it never shows an alert for a model problem, it draws `state`
 * and `notices`.
 */
import type {Tier} from '../../services/deviceRules/types';
import type {Observable} from './common';

export type DeviceClass = 'A' | 'B' | 'C' | 'D' | 'E';
export type Backend = 'metal' | 'opencl' | 'cpu';
export type AttemptKind = 'gpu' | 'gpu_reduced' | 'cpu' | 'cpu_min_context';
export type Platform = 'ios' | 'android';
export type MemoryPressure = 'warning' | 'critical';
export type AuxModel = 'imageGeneration' | 'voice' | 'embeddings';

/** Languages a model supports, as its Hugging Face model card states them. */
export interface ModelLanguages {
  /** ISO 639-1 codes, when the card lists them. */
  codes?: string[];
  /** How many languages the card claims, when it gives a number. */
  count?: number;
  /** The count is a floor ("over 140 languages"). */
  atLeast?: boolean;
  source: string;
}

export interface DownloadProgress {
  receivedBytes: number;
  totalBytes: number;
  /** 0..1 */
  fraction: number;
  bytesPerSecond?: number;
  etaSeconds?: number;
}

export type PauseReason = 'user' | 'offline' | 'metered';

export type FailureReason =
  | 'offline'
  | 'storage_full'
  | 'download_failed'
  | 'checksum_mismatch'
  | 'out_of_memory'
  | 'load_failed'
  | 'file_missing';

export type FailureStage = 'download' | 'verify' | 'load';

export interface LoadedInfo {
  backend: Backend;
  gpuLayers: number;
  contextSize: number;
  vision: boolean;
  /** The attempt that worked; anything but the first planned one is a fallback. */
  attempt: AttemptKind;
  /** True when a fallback attempt was needed. */
  degraded: boolean;
  tokensPerSecond?: number;
}

/**
 *   not_installed -> downloading(progress, paused) -> verifying -> ready
 *   ready -> loading -> loaded
 *   any step -> failed(reason), which remembers where a retry resumes
 */
export type ModelState =
  | {status: 'not_installed'}
  | {
      status: 'downloading';
      progress: DownloadProgress;
      paused: boolean;
      pauseReason?: PauseReason;
    }
  | {status: 'verifying'; fraction: number}
  | {status: 'ready'}
  | {
      status: 'loading';
      attempt?: {index: number; total: number; kind: AttemptKind};
    }
  | {status: 'loaded'; info: LoadedInfo}
  | {
      status: 'failed';
      reason: FailureReason;
      stage: FailureStage;
      /** A retry makes sense without the user changing anything else. */
      retryable: boolean;
      /** The state a retry starts from. */
      resumeTo: 'not_installed' | 'ready';
      detail?: string;
    };

export type ModelStatus = ModelState['status'];

export interface ModelView {
  id: string;
  displayName: string;
  /** Bytes to download for this phone (weights, plus projector if used). */
  downloadBytes: number;
  /** Optional add-on without refusal training. */
  unrestricted: boolean;
  licenceName: string;
  /** False for source-available licences; shown in the picker. */
  openSource: boolean;
  licenceNotice?: string;
  /** The model the app picked for this phone. */
  recommended: boolean;
  /** Whether this phone can run it at all. */
  supported: boolean;
  vision: boolean;
  state: ModelState;
  /**
   * How well it runs here, from the measured memory budget: `great`, `ok`
   * (shorter memory of a chat, or slower), `too_large`. Absent from fakes
   * that predate the store; read it through `fitOf`.
   */
  fit?: 'great' | 'ok' | 'too_large';
  /** For `too_large`: the memory (GB, as marketed) of a phone that runs it. */
  needsRamGb?: number;
  /** One plain line about the model, from the catalogue. */
  summary?: string;
  /** The device class (A–E) the model is sized for. */
  sizedFor?: string;
  /** The weights alone (no projector), for comparing model sizes. */
  weightsBytes?: number;
  /** Known problem: the store leaves it out unless it is installed. */
  heldBack?: boolean;
  /** On the catalogue's measured ladder (evaluated), not a store extra. */
  measured?: boolean;
  /** Unrestricted models: the standard model of the same size it comes from. */
  baseModel?: string;
  /** Supported languages, from the model card; absent when unknown. */
  languages?: ModelLanguages;
}

/**
 * Things the user should know or decide, shown inline (a row, a sheet, a line
 * in chat), never as a blocking alert. `needsAnswer` notices wait for
 * `answerNotice`.
 */
export type ModelNotice =
  /** A download is about to use cellular data. Accept = download anyway. */
  | {
      id: string;
      kind: 'confirm_metered';
      needsAnswer: true;
      modelId: string;
      bytes: number;
    }
  /** The model is slower than the floor. Accept = switch to the smaller one. */
  | {
      id: string;
      kind: 'slow_offer_smaller';
      needsAnswer: true;
      modelId: string;
      offerModelId: string;
      tokensPerSecond: number;
    }
  /** "Low memory: switched to the smaller model". */
  | {
      id: string;
      kind: 'low_memory_switched';
      needsAnswer: false;
      from: string;
      to: string;
    }
  /** The model could not be loaded at all; a smaller one is used instead. */
  | {
      id: string;
      kind: 'load_fell_back';
      needsAnswer: false;
      from: string;
      to: string;
    }
  /** Free space is too small for the phone's proper model. */
  | {
      id: string;
      kind: 'storage_limited';
      needsAnswer: false;
      wantedModelId: string;
      neededBytes: number;
      freeBytes: number;
    };

export type CapabilityReason =
  /** The phone is below the class the feature needs. */
  | {kind: 'needs_class'; minClass: DeviceClass; marketedRamGb: number}
  /** The phone could, but the model in use cannot (e.g. no projector). */
  | {kind: 'model_lacks'}
  | {kind: 'not_offered'};

export interface Capability {
  available: boolean;
  reason?: CapabilityReason;
}

/**
 * What this phone can do, as data for the UI. An unavailable feature is
 * hidden, not shown disabled, except on "What this phone can do".
 */
export interface CapabilityMap {
  deviceClass: DeviceClass;
  modelId: string;
  contextSize: number;
  /** The model answers about images itself. */
  vision: Capability;
  /** How a photo is read: by the model, or by on-device text recognition. */
  imageInput: 'model' | 'ocr';
  audioInput: Capability;
  imageGeneration: Capability;
  /** Hands-free voice conversation. Dictation and read-aloud work everywhere. */
  voiceMode: Capability;
  embeddings: Capability;
  research: Capability;
  followUps: Capability;
  renderHtml: Capability;
  backgroundMemory: Capability;
  tools: Capability;
  /** A "think longer" switch exists for this model. */
  thinking: Capability;
  /** The model cannot switch thinking off reliably. */
  thinkingAlwaysOn: boolean;
  searchQueriesPerTurn: number;
  maxTools: number;
}

/** Everything read from the phone, once, at launch. Memory values are bytes. */
export interface DeviceSnapshot {
  platform: Platform;
  osVersion: string;
  totalRamBytes: number;
  availableBytes?: number;
  footprintBytes?: number;
  freeStorageBytes?: number;
  machine?: string;
  socModel?: string;
  hardware?: string;
  cpuFeatures?: string[];
  maxFreqMhz?: number;
  gpuRenderer?: string;
  isEmulator?: boolean;
}

export interface MemoryBudget {
  platform: Platform;
  weightsPoolBytes: number;
  dirtyPoolBytes: number;
  shared: boolean;
  availableBytes: number;
  source: 'measured' | 'floor';
  measuredAvailableBytes: number;
}

export type GpuUnavailableReason =
  | 'emulator'
  | 'os_too_old'
  | 'no_adreno'
  | 'adreno_too_old'
  | 'missing_cpu_features'
  | 'low_memory';

export interface GpuHint {
  backend: Backend;
  reason?: GpuUnavailableReason;
  maxGpuLayers: number;
}

export interface DeviceProfile {
  snapshot: DeviceSnapshot;
  deviceClass: DeviceClass;
  memoryClass: DeviceClass;
  chipClass: DeviceClass;
  upstreamTier: Tier;
  budget: MemoryBudget;
  gpu: GpuHint;
  osMajor: number;
  knownIssues: string[];
}

export type EnginePhase = 'idle' | 'initializing' | 'ready';

export interface PressureContext {
  generating: boolean;
  aux: AuxModel[];
}

export interface ModelPort extends Observable {
  readonly phase: EnginePhase;
  readonly device: DeviceProfile | null;
  readonly deviceClass: DeviceClass | null;
  /** What this phone can do with the model in use (or the recommended one). */
  readonly capabilities: CapabilityMap | null;
  /** Every model the phone may install, recommended first. */
  readonly models: ModelView[];
  readonly recommendedModelId: string | null;
  /** The unrestricted add-on for this phone, if one fits. */
  readonly unrestrictedModelId: string | null;
  /** The model that is loaded or loading. */
  readonly activeModelId: string | null;
  readonly notices: ModelNotice[];

  stateOf(modelId: string): ModelState;

  /** Detect the phone, pick the model, find what is already installed. */
  initialize(): Promise<void>;
  /** First run: download the recommended model and load it. */
  getStarted(): Promise<void>;

  download(modelId: string, options?: {allowMetered?: boolean}): Promise<void>;
  pause(modelId: string): void;
  resume(modelId: string): Promise<void>;
  cancel(modelId: string): Promise<void>;
  remove(modelId: string): Promise<void>;
  load(modelId: string): Promise<void>;
  unload(): Promise<void>;
  /** Retry whatever failed, from where it failed. */
  retry(modelId: string): Promise<void>;

  answerNotice(noticeId: string, accept: boolean): Promise<void>;
  dismissNotice(noticeId: string): void;

  /** Chat reports streamed tokens so the engine can measure speed after load. */
  noteGeneratedTokens(count: number): void;
  /** Chat reports the end of an answer (deferred memory actions run now). */
  noteGenerationFinished(): Promise<void>;
  /** The OS reported memory pressure. */
  onMemoryPressure(
    level: MemoryPressure,
    context: PressureContext,
  ): Promise<void>;
  /** Connectivity changed: pause or resume downloads accordingly. */
  onNetworkChange(): Promise<void>;
}
