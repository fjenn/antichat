import type {CapabilityMap} from './capabilities';
import type {DeviceClass, ModelLanguages} from './catalog/types';
import type {DeviceProfile} from './device/types';
import type {AuxModel, MemoryPressure} from './policy/lowMemory';
import type {ModelState} from './state';

/**
 * ModelPort: everything the UI needs from the model engine.
 *
 * Defined here for now; it moves to `src/antichat/contracts/` with the other
 * ports. The UI reads the observable fields and calls the commands; it never
 * shows an alert for a model problem, it draws `state` and `notices`.
 */

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
  /** How well it runs here (see `policy/storeFit.ts`). */
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

export type EnginePhase = 'idle' | 'initializing' | 'ready';

export interface PressureContext {
  generating: boolean;
  aux: AuxModel[];
}

export interface ModelPort {
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

  /** Change notification for consumers that do not use MobX. */
  subscribe(listener: () => void): () => void;
}
