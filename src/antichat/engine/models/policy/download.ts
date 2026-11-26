import type {Catalog, CatalogFile, CatalogPolicy} from '../catalog/types';
import type {DeviceProfile} from '../device/types';

import {ModelChoice, Selection, selectModel, SelectionHistory} from './select';

/** What the connectivity layer knows; see `engine/connectivity`. */
export interface NetworkStatus {
  online: boolean;
  /** Cellular or otherwise billed by volume. */
  metered: boolean;
}

export type DownloadDecision =
  /** Everything is already on disk. */
  | {kind: 'installed'}
  | {kind: 'start'; files: CatalogFile[]; bytes: number}
  /** On cellular: ask once, showing the size. */
  | {kind: 'confirm_metered'; files: CatalogFile[]; bytes: number}
  | {kind: 'blocked'; reason: 'offline'; bytes: number}
  | {
      kind: 'blocked';
      reason: 'storage';
      bytes: number;
      neededBytes: number;
      freeBytes: number;
    };

/** Free space a download of `bytes` needs, including the safety margin. */
export function requiredFreeBytes(
  bytes: number,
  policy: CatalogPolicy,
): number {
  return (
    bytes +
    Math.max(policy.storage.marginBytes, bytes * policy.storage.marginFraction)
  );
}

export interface DownloadEnvironment {
  network: NetworkStatus;
  /** Null when the free-space read failed: storage is then not checked. */
  freeStorageBytes: number | null;
  /** Bytes already on disk for a file (complete or partial), 0 if none. */
  bytesOnDisk?: (file: CatalogFile) => number;
  /** The user already agreed to use cellular data for this download. */
  allowMetered?: boolean;
}

/** Storage is checked before the network, so "no space" is said first. */
export function decideDownload(
  files: CatalogFile[],
  env: DownloadEnvironment,
  policy: CatalogPolicy,
): DownloadDecision {
  const missing = files
    .map(file => ({
      file,
      remaining: Math.max(0, file.sizeBytes - (env.bytesOnDisk?.(file) ?? 0)),
    }))
    .filter(entry => entry.remaining > 0);
  if (missing.length === 0) {
    return {kind: 'installed'};
  }
  const pending = missing.map(entry => entry.file);
  const bytes = missing.reduce((sum, entry) => sum + entry.remaining, 0);

  if (env.freeStorageBytes !== null) {
    const neededBytes = requiredFreeBytes(bytes, policy);
    if (env.freeStorageBytes < neededBytes) {
      return {
        kind: 'blocked',
        reason: 'storage',
        bytes,
        neededBytes,
        freeBytes: env.freeStorageBytes,
      };
    }
  }
  if (!env.network.online) {
    return {kind: 'blocked', reason: 'offline', bytes};
  }
  if (env.network.metered && !env.allowMetered) {
    return {kind: 'confirm_metered', files: pending, bytes};
  }
  return {kind: 'start', files: pending, bytes};
}

export interface FirstRunPlan {
  selection: Selection;
  decision: DownloadDecision;
  /**
   * Set when the phone's proper model does not fit the free space and a smaller
   * one was planned instead; the UI can say what freeing space would unlock.
   */
  storageLimited?: {
    wanted: ModelChoice;
    neededBytes: number;
    freeBytes: number;
  };
}

/**
 * First-run plan: pick the model, then make sure it can be stored. If the free
 * space is too small, walk further down the ladder to one that fits on disk
 * rather than stopping the user at a storage error.
 */
export function planFirstRun(
  profile: DeviceProfile,
  catalog: Catalog,
  env: DownloadEnvironment,
  history: SelectionHistory = {},
): FirstRunPlan {
  const first = selectModel(profile, catalog, history);
  let selection = first;
  let decision = decideDownload(selection.files, env, catalog.policy);
  let storageLimited: FirstRunPlan['storageLimited'];
  let working: SelectionHistory = history;

  while (decision.kind === 'blocked' && decision.reason === 'storage') {
    storageLimited ??= {
      wanted: first,
      neededBytes: decision.neededBytes,
      freeBytes: decision.freeBytes,
    };
    working = {
      ...working,
      demoted: {...working.demoted, [selection.model.id]: 'storage'},
    };
    const next = selectModel(profile, catalog, working);
    if (
      next.model.id === selection.model.id ||
      next.downloadBytes >= selection.downloadBytes
    ) {
      // Nothing smaller left: report the block for the proper model.
      return {
        selection: first,
        decision: decideDownload(first.files, env, catalog.policy),
      };
    }
    selection = next;
    decision = decideDownload(selection.files, env, catalog.policy);
  }
  return {selection, decision, storageLimited};
}

/** Rough download time for the first-run line ("about 4 min on Wi-Fi"). */
export function estimateDownloadSeconds(
  bytes: number,
  bytesPerSecond: number,
): number | null {
  return bytesPerSecond > 0 ? Math.ceil(bytes / bytesPerSecond) : null;
}
