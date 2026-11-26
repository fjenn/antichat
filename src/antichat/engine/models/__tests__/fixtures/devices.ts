import {bundledCatalog} from '../../catalog/bundledCatalog';
import type {Catalog} from '../../catalog/types';
import {classifyDevice} from '../../device/classify';
import type {DeviceProfile, DeviceSnapshot} from '../../device/types';

export const GiB = 1024 ** 3;
export const GB = 1000 ** 3;
export const MB = 1024 * 1024;

export const ios = (
  ramGiB: number,
  availableGb: number | undefined,
  machine = 'iPhone18,1',
  extra: Partial<DeviceSnapshot> = {},
): DeviceSnapshot => ({
  platform: 'ios',
  osVersion: '26.6',
  totalRamBytes: ramGiB * GiB,
  availableBytes: availableGb === undefined ? undefined : availableGb * GB,
  machine,
  ...extra,
});

export const android = (
  ramGiB: number,
  availableGb: number | undefined,
  socModel = 'SM8750',
  extra: Partial<DeviceSnapshot> = {},
): DeviceSnapshot => ({
  platform: 'android',
  osVersion: '16',
  totalRamBytes: ramGiB * GiB,
  availableBytes: availableGb === undefined ? undefined : availableGb * GB,
  socModel,
  cpuFeatures: ['asimddp', 'i8mm'],
  gpuRenderer: 'Adreno (TM) 830',
  ...extra,
});

export const profile = (
  snapshot: DeviceSnapshot,
  catalog: Catalog = bundledCatalog,
): DeviceProfile => classifyDevice(snapshot, catalog);

/** Typical phones per class, used across the policy tests. */
export const PHONE = {
  A: () => profile(ios(3.75, 2.1, 'iPhone14,5')),
  B: () => profile(ios(5.6, 3.12, 'iPhone14,2')),
  C: () => profile(ios(7.5, 3.0, 'iPhone17,1')),
  D: () => profile(ios(11.45, 3.17, 'iPhone18,1')),
  DRaised: () => profile(ios(11.45, 7.8, 'iPhone18,2')),
  E: () => profile(android(15, 6)),
};
