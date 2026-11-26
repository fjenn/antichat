import type {CatalogPolicy} from '../catalog/types';

import {DeviceSnapshot, MemoryBudget} from './types';

/**
 * Turn the launch-time memory reading into a budget for model memory.
 *
 * iOS. `os_proc_available_memory()` is the real distance to the app's memory
 * limit, so it is trusted as read. Memory-mapped weights are file-backed and do
 * not count against that limit (llama.cpp's Metal backend wraps the mapping
 * without copying), but they still need physical RAM. Hence two pools:
 *   weights + projector  <= weightsFractionOfRam * physical RAM
 *   KV cache + buffers   <= dirtyFractionOfAvailable * measured available
 * Only when the reading is missing or zero (the Simulator) is a per-RAM floor
 * used instead.
 *
 * Android. `MemoryInfo.availMem` is a system-wide snapshot that ignores memory
 * the OS would reclaim from cached apps, so a flagship read right after boot
 * can report 2 GB (PocketPal issue #982, where that first reading then became
 * the permanent ceiling). The reading is therefore floored with a share of
 * total RAM. The share and the reserve are ported from Off Grid's
 * `memoryBudget.ts` (MIT, (c) Mohammed Ali Chherawalla).
 */
export function computeMemoryBudget(
  snapshot: DeviceSnapshot,
  policy: CatalogPolicy,
): MemoryBudget {
  const total = Math.max(0, snapshot.totalRamBytes);
  const measured =
    typeof snapshot.availableBytes === 'number' &&
    Number.isFinite(snapshot.availableBytes) &&
    snapshot.availableBytes > 0
      ? snapshot.availableBytes
      : 0;

  if (snapshot.platform === 'ios') {
    const floor = stepValue(policy.ios.availableFloor, total, 'bytes');
    const useFloor = measured === 0;
    // Never assume more than the phone has.
    const available = useFloor ? Math.min(floor, total) : measured;
    return {
      platform: 'ios',
      weightsPoolBytes: total * policy.ios.weightsFractionOfRam,
      dirtyPoolBytes: available * policy.ios.dirtyFractionOfAvailable,
      shared: false,
      availableBytes: available,
      source: useFloor ? 'floor' : 'measured',
      measuredAvailableBytes: measured,
    };
  }

  const floor = androidFloorBytes(total, policy);
  const useFloor = measured < floor;
  // A reading above physical RAM is a broken reading.
  const pool = useFloor ? floor : Math.min(measured, total);
  return {
    platform: 'android',
    weightsPoolBytes: pool,
    dirtyPoolBytes: pool,
    shared: true,
    availableBytes: pool,
    source: useFloor ? 'floor' : 'measured',
    measuredAvailableBytes: measured,
  };
}

/**
 * The #982 floor: the smaller of a share of total RAM and total RAM minus the
 * OS reserve, never negative.
 */
export function androidFloorBytes(
  totalRamBytes: number,
  policy: CatalogPolicy,
): number {
  const fraction = stepValue(
    policy.android.budgetFractions,
    totalRamBytes,
    'fraction',
  );
  return Math.max(
    0,
    Math.min(
      totalRamBytes * fraction,
      totalRamBytes - policy.android.reserveBytes,
    ),
  );
}

/** Value of the first step whose bound is at or above `ramBytes`. */
export function stepValue<K extends string>(
  steps: Array<{maxRamBytes: number | null} & Record<K, number>>,
  ramBytes: number,
  key: K,
): number {
  const step =
    steps.find(s => s.maxRamBytes === null || ramBytes <= s.maxRamBytes) ??
    steps[steps.length - 1];
  return step[key];
}
