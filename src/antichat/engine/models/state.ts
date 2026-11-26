import type {Backend} from './catalog/types';
import type {AttemptKind} from './policy/initChain';

/**
 * Typed model state for the UI. Replaces PocketPal's alert dialogs: every
 * situation the user can be in is a state with data, and the screen draws it.
 *
 *   not_installed -> downloading(progress, paused) -> verifying -> ready
 *   ready -> loading -> loaded
 *   any step -> failed(reason), which remembers where a retry resumes
 */

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

export type ModelEvent =
  | {type: 'FOUND_ON_DISK'}
  | {type: 'DOWNLOAD_STARTED'; totalBytes: number; receivedBytes?: number}
  | {
      type: 'DOWNLOAD_PROGRESS';
      receivedBytes: number;
      bytesPerSecond?: number;
    }
  | {type: 'DOWNLOAD_PAUSED'; reason: PauseReason}
  | {type: 'DOWNLOAD_RESUMED'}
  | {type: 'DOWNLOAD_COMPLETED'}
  | {type: 'DOWNLOAD_CANCELLED'}
  | {
      type: 'DOWNLOAD_FAILED';
      reason: Extract<
        FailureReason,
        'offline' | 'storage_full' | 'download_failed'
      >;
      detail?: string;
    }
  | {type: 'VERIFY_PROGRESS'; fraction: number}
  | {type: 'VERIFY_PASSED'}
  | {type: 'VERIFY_FAILED'; detail?: string}
  | {type: 'LOAD_STARTED'}
  | {type: 'LOAD_ATTEMPT'; index: number; total: number; kind: AttemptKind}
  | {type: 'LOAD_SUCCEEDED'; info: LoadedInfo}
  | {
      type: 'LOAD_FAILED';
      reason: Extract<
        FailureReason,
        'out_of_memory' | 'load_failed' | 'file_missing'
      >;
      detail?: string;
    }
  | {type: 'SPEED_MEASURED'; tokensPerSecond: number}
  | {type: 'UNLOADED'}
  | {type: 'RETRY'}
  | {type: 'REMOVED'};

export const NOT_INSTALLED: ModelState = {status: 'not_installed'};
export const READY: ModelState = {status: 'ready'};

const clamp01 = (value: number): number =>
  Number.isFinite(value) ? Math.min(1, Math.max(0, value)) : 0;

export function makeProgress(
  receivedBytes: number,
  totalBytes: number,
  bytesPerSecond?: number,
): DownloadProgress {
  const received = Math.max(0, Math.min(receivedBytes, totalBytes));
  const progress: DownloadProgress = {
    receivedBytes: received,
    totalBytes,
    fraction: totalBytes > 0 ? clamp01(received / totalBytes) : 0,
  };
  if (bytesPerSecond !== undefined && bytesPerSecond > 0) {
    progress.bytesPerSecond = bytesPerSecond;
    progress.etaSeconds = Math.ceil((totalBytes - received) / bytesPerSecond);
  }
  return progress;
}

/**
 * The state machine. Returns the next state, or the SAME object when the event
 * does not apply in the current state, so a late or duplicated native callback
 * can never move the UI somewhere impossible.
 */
export function transition(state: ModelState, event: ModelEvent): ModelState {
  switch (event.type) {
    case 'FOUND_ON_DISK':
      return state.status === 'not_installed' ? READY : state;

    case 'DOWNLOAD_STARTED':
      return state.status === 'not_installed'
        ? {
            status: 'downloading',
            progress: makeProgress(event.receivedBytes ?? 0, event.totalBytes),
            paused: false,
          }
        : state;

    case 'DOWNLOAD_PROGRESS':
      // Progress never moves backwards and never un-pauses.
      return state.status === 'downloading' &&
        event.receivedBytes >= state.progress.receivedBytes
        ? {
            ...state,
            progress: makeProgress(
              event.receivedBytes,
              state.progress.totalBytes,
              state.paused ? undefined : event.bytesPerSecond,
            ),
          }
        : state;

    case 'DOWNLOAD_PAUSED':
      return state.status === 'downloading' && !state.paused
        ? {
            status: 'downloading',
            progress: makeProgress(
              state.progress.receivedBytes,
              state.progress.totalBytes,
            ),
            paused: true,
            pauseReason: event.reason,
          }
        : state;

    case 'DOWNLOAD_RESUMED':
      return state.status === 'downloading' && state.paused
        ? {status: 'downloading', progress: state.progress, paused: false}
        : state;

    case 'DOWNLOAD_COMPLETED':
      return state.status === 'downloading'
        ? {status: 'verifying', fraction: 0}
        : state;

    case 'DOWNLOAD_CANCELLED':
      return state.status === 'downloading' ? NOT_INSTALLED : state;

    case 'DOWNLOAD_FAILED':
      return state.status === 'downloading' || state.status === 'not_installed'
        ? {
            status: 'failed',
            reason: event.reason,
            stage: 'download',
            // Storage needs the user to free space first.
            retryable: event.reason !== 'storage_full',
            resumeTo: 'not_installed',
            detail: event.detail,
          }
        : state;

    case 'VERIFY_PROGRESS':
      return state.status === 'verifying'
        ? {status: 'verifying', fraction: clamp01(event.fraction)}
        : state;

    case 'VERIFY_PASSED':
      return state.status === 'verifying' ? READY : state;

    case 'VERIFY_FAILED':
      return state.status === 'verifying'
        ? {
            status: 'failed',
            reason: 'checksum_mismatch',
            stage: 'verify',
            retryable: true,
            resumeTo: 'not_installed',
            detail: event.detail,
          }
        : state;

    case 'LOAD_STARTED':
      return state.status === 'ready' ? {status: 'loading'} : state;

    case 'LOAD_ATTEMPT':
      return state.status === 'loading'
        ? {
            status: 'loading',
            attempt: {index: event.index, total: event.total, kind: event.kind},
          }
        : state;

    case 'LOAD_SUCCEEDED':
      return state.status === 'loading'
        ? {status: 'loaded', info: event.info}
        : state;

    case 'LOAD_FAILED':
      return state.status === 'loading' || state.status === 'ready'
        ? {
            status: 'failed',
            reason: event.reason,
            stage: 'load',
            retryable: event.reason !== 'file_missing',
            // A missing file has to be downloaded again.
            resumeTo:
              event.reason === 'file_missing' ? 'not_installed' : 'ready',
            detail: event.detail,
          }
        : state;

    case 'SPEED_MEASURED':
      return state.status === 'loaded'
        ? {
            status: 'loaded',
            info: {...state.info, tokensPerSecond: event.tokensPerSecond},
          }
        : state;

    case 'UNLOADED':
      return state.status === 'loaded' || state.status === 'loading'
        ? READY
        : state;

    case 'RETRY':
      return state.status === 'failed'
        ? state.resumeTo === 'ready'
          ? READY
          : NOT_INSTALLED
        : state;

    case 'REMOVED':
      // Files of a model that is downloading are removed by cancelling.
      return state.status === 'downloading' ? state : NOT_INSTALLED;
  }
}

/** Whether an event would change the state. */
export const canApply = (state: ModelState, event: ModelEvent): boolean =>
  transition(state, event) !== state;

/** The model's files are complete and verified on disk. */
export const isInstalled = (state: ModelState): boolean =>
  state.status === 'ready' ||
  state.status === 'loading' ||
  state.status === 'loaded' ||
  (state.status === 'failed' && state.resumeTo === 'ready');
