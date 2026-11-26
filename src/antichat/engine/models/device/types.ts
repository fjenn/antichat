import type {Tier} from '../../../../services/deviceRules/types';
import type {Backend, DeviceClass} from '../catalog/types';

export type Platform = 'ios' | 'android';

/**
 * Everything read from the phone, once, at launch. All memory values are bytes.
 * Plain data so tests and the device table can describe a phone by hand.
 */
export interface DeviceSnapshot {
  platform: Platform;
  /** "26.6.2" on iOS, the API level or release ("15") on Android. */
  osVersion: string;
  /** Physical RAM as the OS reports it (a "12 GB" phone reports about 11.4 GiB). */
  totalRamBytes: number;
  /**
   * Memory the OS says this app may still use, read at launch:
   * `os_proc_available_memory()` on iOS, `MemoryInfo.availMem` on Android.
   * Undefined or 0 when the read failed (always 0 on the iOS Simulator).
   */
  availableBytes?: number;
  /** iOS `phys_footprint` at the same moment, when known. */
  footprintBytes?: number;
  freeStorageBytes?: number;
  /** iOS `hw.machine`, e.g. "iPhone18,1". */
  machine?: string;
  /** Android `Build.SOC_MODEL`, e.g. "SM8650". */
  socModel?: string;
  /** Android `Build.HARDWARE`. */
  hardware?: string;
  cpuFeatures?: string[];
  maxFreqMhz?: number;
  /** Android GL renderer string, e.g. "Adreno (TM) 750". */
  gpuRenderer?: string;
  isEmulator?: boolean;
}

/** How much memory a model may use, and how we know. */
export interface MemoryBudget {
  platform: Platform;
  /**
   * iOS: bytes of memory-mapped weights (model + projector) the phone can hold.
   * Android: the single pool that weights and working memory share.
   */
  weightsPoolBytes: number;
  /**
   * iOS: bytes for the KV cache, buffers and projector working memory, which
   * count against the app's memory limit. Android: same pool as the weights.
   */
  dirtyPoolBytes: number;
  /** True on Android, where both kinds of memory come out of one pool. */
  shared: boolean;
  /** The available-memory figure the pools were derived from. */
  availableBytes: number;
  /** `measured`: the OS reading was used. `floor`: it was missing or too low. */
  source: 'measured' | 'floor';
  /** The raw OS reading, kept for diagnostics. */
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
  /** Why the GPU is not used; undefined when `backend` is a GPU backend. */
  reason?: GpuUnavailableReason;
  /** Upper bound on offloaded layers; 0 on CPU. */
  maxGpuLayers: number;
}

export interface DeviceProfile {
  snapshot: DeviceSnapshot;
  deviceClass: DeviceClass;
  /** The class memory alone would allow. */
  memoryClass: DeviceClass;
  /** The class the chip allows (upstream tier mapped through `tierCap`). */
  chipClass: DeviceClass;
  /** PocketPal's own tier for this phone. */
  upstreamTier: Tier;
  budget: MemoryBudget;
  gpu: GpuHint;
  osMajor: number;
  /** Known runtime problems on this OS build, by issue id. */
  knownIssues: string[];
}
