/**
 * Model catalogue: the data that decides which model a phone gets.
 *
 * The catalogue is plain JSON so a default model can change without an app
 * release. A copy is bundled with the app (`bundled.json`); a signed newer copy
 * may replace it at runtime (see `store.ts`).
 */

export const CATALOG_SCHEMA_VERSION = 1;

/** Device classes, smallest to largest. Roughly 4 / 6 / 8 / 12 / 16 GB phones. */
export const DEVICE_CLASSES = ['A', 'B', 'C', 'D', 'E'] as const;
export type DeviceClass = (typeof DEVICE_CLASSES)[number];

export type Backend = 'metal' | 'opencl' | 'cpu';

export interface CatalogFile {
  /** Hugging Face repository, "owner/name". */
  repo: string;
  /** Path of the file inside the repository. */
  path: string;
  /** Pinned commit, so a re-upload cannot change what we verified. */
  revision: string;
  sizeBytes: number;
  /** Lower-case hex SHA-256 (the Hugging Face LFS object id). */
  sha256: string;
  quant: string;
}

export interface WeightsFile extends CatalogFile {
  /** Backends this quantisation is meant for. Absent = all. */
  backends?: Backend[];
}

export interface ProjectorFile extends CatalogFile {
  modalities: Array<'image' | 'audio'>;
}

export interface Licence {
  id: string;
  name: string;
  url: string;
  /** False for source-available licences; the model picker says so. */
  openSource: boolean;
  notice?: string;
}

export interface ModelTemplate {
  jinja: boolean;
  /** Tool-call markup the chat template produces. */
  toolFormat: string;
  thinking: {
    supported: boolean;
    /** Whether thinking is on when the user has not chosen. */
    default: boolean;
    /** False when the model cannot reliably switch thinking off. */
    canDisable: boolean;
  };
}

/**
 * Languages the model supports, as its Hugging Face model card states them
 * (`language` metadata, or the card's own list or count). Absent when the
 * card says nothing; never guessed.
 */
export interface ModelLanguages {
  /** ISO 639-1 codes, when the card lists them. */
  codes?: string[];
  /** How many languages the card claims, when it gives a number, not a list. */
  count?: number;
  /** The count is a floor ("over 140 languages"). */
  atLeast?: boolean;
  /** The Hugging Face repository the information comes from. */
  source: string;
}

export interface ModelCapabilities {
  tools: boolean;
  vision: boolean;
  audio: boolean;
  thinking: boolean;
}

export interface ModelMemory {
  /** Key/value cache cost of one context token, f16 cache. */
  kvBytesPerToken: number;
  /** Compute buffers and runtime overhead that do not grow with context. */
  fixedBytes: number;
  /**
   * Smallest measured memory the model may be auto-selected with: on iOS the
   * available memory read at launch, on Android the model pool (see
   * `device/memory.ts`). Overrides the computed estimate upwards once real
   * device measurements exist.
   */
  minMeasuredAvailableBytes: {ios: number; android: number};
  /** Where the numbers come from. */
  basis: 'device-measured' | 'gguf-upper-bound' | 'estimate';
  note?: string;
}

export interface CatalogModel {
  id: string;
  displayName: string;
  family: string;
  params: string;
  licence: Licence;
  /** The device class this model is sized for. */
  tier: DeviceClass;
  /** `default`/`fallback` models are on a ladder; `alternative` is manual only. */
  role: 'default' | 'fallback' | 'alternative';
  /** True for the optional add-on without refusal training. */
  unrestricted: boolean;
  /** One or more quantisations of the same weights. */
  files: WeightsFile[];
  projector?: ProjectorFile;
  context: {trained: number; default: number; max: number};
  template: ModelTemplate;
  capabilities: ModelCapabilities;
  languages?: ModelLanguages;
  memory: ModelMemory;
  /** The standard model an unrestricted model was derived from. */
  baseModel?: string;
  /** Measured quality and speed; informational, shown in "Details". */
  eval?: Record<string, unknown>;
  /** Known problem: kept out of the model store until fixed. */
  heldBack?: boolean;
  /** One plain line for the model store ("Small and quick."). */
  summary?: string;
  note?: string;
}

export interface ClassFeatures {
  vision: boolean;
  imageGeneration: boolean;
  voiceMode: boolean;
  /** An embedding model can stay loaded beside the chat model. */
  embeddings: boolean;
  research: boolean;
  followUps: boolean;
  renderHtml: boolean;
  backgroundMemory: boolean;
  searchQueriesPerTurn: number;
  maxTools: number;
}

export interface ClassUpgrade {
  modelId: string;
  /** `offer`: shown as an optional better model. `auto`: becomes the default. */
  mode: 'offer' | 'auto';
  /** Extra floor on the launch-time memory reading before the upgrade applies. */
  minMeasuredAvailableBytes?: {ios?: number; android?: number};
}

export interface CatalogClass {
  id: DeviceClass;
  /** The marketed RAM this class corresponds to, for user-facing copy only. */
  marketedRamGb: number;
  requires: {
    ios: {weightsPoolBytes: number; dirtyPoolBytes: number};
    android: {poolBytes: number};
  };
  defaultModel: string;
  contextSize: number;
  /** Null where no tested unrestricted model fits the class. */
  unrestrictedModel: string | null;
  upgrade?: ClassUpgrade;
  features: ClassFeatures;
}

/** The embedding model for memory and file retrieval (one for all classes). */
export interface CatalogEmbedding {
  /** Stored with every vector; a new id re-makes all vectors. */
  id: string;
  displayName: string;
  licence: Licence;
  file: CatalogFile;
  nativeDims: number;
  /** Dimensions kept (Matryoshka cut). */
  dims: number;
  contextSize: number;
  /** Resident memory while loaded, weights and context together. */
  ramBytes: number;
}

export interface CatalogPolicy {
  speedFloorTokPerSec: number;
  calibrationSeconds: number;
  minContextSize: number;
  preferredMinContextSize: number;
  /** Working memory of a loaded vision projector. */
  visionWorkingBytes: number;
  storage: {marginBytes: number; marginFraction: number};
  ios: {
    weightsFractionOfRam: number;
    dirtyFractionOfAvailable: number;
    /** Assumed available memory when the reading is missing or zero. */
    availableFloor: Array<{maxRamBytes: number | null; bytes: number}>;
  };
  android: {
    overheadFactor: number;
    reserveBytes: number;
    budgetFractions: Array<{maxRamBytes: number | null; fraction: number}>;
  };
  /** Highest class each upstream (PocketPal) tier may reach. */
  tierCap: Record<'low' | 'mid' | 'high' | 'flagship', DeviceClass>;
  gpu: {
    iosMinMajor: number;
    iosMetalReserveBytes: number;
    adrenoMinGeneration: number;
    /** At or below this much RAM the GPU is not tried at all. */
    noGpuMaxRamBytes: {ios: number; android: number};
    androidLayerCaps: Array<{maxRamBytes: number | null; layers: number}>;
    initTimeoutMs: {ios: number; android: number};
  };
}

export interface Catalog {
  schemaVersion: number;
  /** Monotonic; a remote catalogue with a lower serial is a rollback. */
  serial: number;
  issuedAt: string;
  /** ISO date after which a remote copy is no longer trusted; null = never. */
  expiresAt: string | null;
  minAppVersion: string;
  sources?: string;
  policy: CatalogPolicy;
  /** Standard models, largest first. Stepping down walks this list. */
  ladder: string[];
  /** Unrestricted add-ons, largest first. */
  unrestrictedLadder: string[];
  classes: CatalogClass[];
  models: CatalogModel[];
  /** Absent in catalogues written before file chat; retrieval is then keyword only. */
  embedding?: CatalogEmbedding;
  /** Model ids or file SHA-256 values that must no longer be offered. */
  revoked: string[];
}
