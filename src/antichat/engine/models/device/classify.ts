import {classify} from '../../../../services/deviceRules/classify';
import {parseDeviceRules} from '../../../../services/deviceRules/parse';
import type {Classifier, Tier} from '../../../../services/deviceRules/types';
import androidRulesRaw from '../../../../store/bundledDeviceRules/rules.android.json';
import iosRulesRaw from '../../../../store/bundledDeviceRules/rules.ios.json';
import {
  Catalog,
  CatalogPolicy,
  DEVICE_CLASSES,
  DeviceClass,
} from '../catalog/types';

import {computeMemoryBudget, stepValue} from './memory';
import {
  DeviceProfile,
  DeviceSnapshot,
  GpuHint,
  MemoryBudget,
  Platform,
} from './types';

/**
 * Device classifier.
 *
 * Two independent questions, and the phone gets the lower answer:
 *  - memory: the highest class whose requirements the MEASURED budget meets
 *    (see `memory.ts`); marketed RAM plays no part;
 *  - chip: PocketPal's bundled device rules map the chip to a tier, and the
 *    catalogue caps each tier at a class, so a slow chip with plenty of RAM
 *    does not get a model it would run at two tokens a second.
 */

export type UpstreamClassifiers = Record<Platform, Classifier>;

let bundledClassifiers: UpstreamClassifiers | null = null;

/** PocketPal's bundled chip tables, parsed once. */
export function upstreamClassifiers(): UpstreamClassifiers {
  if (bundledClassifiers === null) {
    // Only the classifier part is used; the app-version gate applies to the
    // model candidates, which we ignore.
    bundledClassifiers = {
      ios: parseDeviceRules(iosRulesRaw, '0.0.0').classifier,
      android: parseDeviceRules(androidRulesRaw, '0.0.0').classifier,
    };
  }
  return bundledClassifiers;
}

export const classIndex = (id: DeviceClass): number =>
  DEVICE_CLASSES.indexOf(id);

export const lowerClass = (a: DeviceClass, b: DeviceClass): DeviceClass =>
  classIndex(a) <= classIndex(b) ? a : b;

export function osMajorOf(osVersion: string): number {
  const major = parseInt(osVersion, 10);
  return Number.isFinite(major) ? major : 0;
}

/** Highest class whose memory requirements the budget meets. */
export function memoryClassFor(
  budget: MemoryBudget,
  catalog: Catalog,
): DeviceClass {
  let best: DeviceClass = 'A';
  for (const cls of catalog.classes) {
    const meets =
      budget.platform === 'ios'
        ? budget.weightsPoolBytes >= cls.requires.ios.weightsPoolBytes &&
          budget.dirtyPoolBytes >= cls.requires.ios.dirtyPoolBytes
        : budget.weightsPoolBytes >= cls.requires.android.poolBytes;
    if (meets && classIndex(cls.id) > classIndex(best)) {
      best = cls.id;
    }
  }
  return best;
}

/** "Adreno (TM) 750" -> 750; null for other GPUs. */
export function adrenoGeneration(renderer: string | undefined): number | null {
  const match = renderer?.match(/adreno[^0-9]*(\d{3,4})/i);
  return match ? parseInt(match[1], 10) : null;
}

/**
 * Which accelerator to try first. The rules are ported from PocketPal's
 * `checkGpuSupport` (Metal needs iOS 18; OpenCL needs Adreno plus i8mm and
 * dotprod) and Off Grid's `llmDeviceLimits.ts` (no GPU at 4 GB or less,
 * Adreno layer caps by RAM), with the research finding that OpenCL is only
 * worth it on Adreno 700 and later. The 4 GB rule is applied on Android only:
 * on iOS the weights are mapped, not copied, and the load journal catches a
 * Metal allocation that kills the app (see `policy/initChain.ts`).
 */
export function gpuHintFor(
  snapshot: DeviceSnapshot,
  policy: CatalogPolicy,
): GpuHint {
  const cpu = (reason: GpuHint['reason']): GpuHint => ({
    backend: 'cpu',
    reason,
    maxGpuLayers: 0,
  });
  if (snapshot.isEmulator) {
    return cpu('emulator');
  }
  if (
    snapshot.totalRamBytes <= policy.gpu.noGpuMaxRamBytes[snapshot.platform]
  ) {
    return cpu('low_memory');
  }
  if (snapshot.platform === 'ios') {
    return osMajorOf(snapshot.osVersion) >= policy.gpu.iosMinMajor
      ? {backend: 'metal', maxGpuLayers: 99}
      : cpu('os_too_old');
  }
  const generation = adrenoGeneration(snapshot.gpuRenderer);
  if (generation === null) {
    return cpu('no_adreno');
  }
  if (generation < policy.gpu.adrenoMinGeneration) {
    return cpu('adreno_too_old');
  }
  const features = snapshot.cpuFeatures ?? [];
  const hasDotprod =
    features.includes('dotprod') || features.includes('asimddp');
  if (!features.includes('i8mm') || !hasDotprod) {
    return cpu('missing_cpu_features');
  }
  const layers = stepValue(
    policy.gpu.androidLayerCaps,
    snapshot.totalRamBytes,
    'layers',
  );
  return layers > 0
    ? {backend: 'opencl', maxGpuLayers: layers}
    : cpu('low_memory');
}

/** Runtime problems tied to an OS build, so the UI can explain a failure. */
export function knownIssuesFor(snapshot: DeviceSnapshot): string[] {
  const issues: string[] = [];
  if (snapshot.platform === 'ios' && /^27\.2\.1\b/.test(snapshot.osVersion)) {
    // llama.rn #439: completions return zero tokens on iOS 27.2.1.
    issues.push('llama.rn#439');
  }
  return issues;
}

export function upstreamTierFor(
  snapshot: DeviceSnapshot,
  classifiers: UpstreamClassifiers = upstreamClassifiers(),
): Tier {
  return classify(
    {
      ramBytes: snapshot.totalRamBytes,
      machine: snapshot.machine,
      socModel: snapshot.socModel,
      hardware: snapshot.hardware,
      cpuFeatures: snapshot.cpuFeatures,
      maxFreqMhz: snapshot.maxFreqMhz,
    },
    classifiers[snapshot.platform],
    snapshot.platform,
  );
}

export function classifyDevice(
  snapshot: DeviceSnapshot,
  catalog: Catalog,
  classifiers: UpstreamClassifiers = upstreamClassifiers(),
): DeviceProfile {
  const budget = computeMemoryBudget(snapshot, catalog.policy);
  const memoryClass = memoryClassFor(budget, catalog);
  const upstreamTier = upstreamTierFor(snapshot, classifiers);
  const chipClass = catalog.policy.tierCap[upstreamTier];
  return {
    snapshot,
    deviceClass: lowerClass(memoryClass, chipClass),
    memoryClass,
    chipClass,
    upstreamTier,
    budget,
    gpu: gpuHintFor(snapshot, catalog.policy),
    osMajor: osMajorOf(snapshot.osVersion),
    knownIssues: knownIssuesFor(snapshot),
  };
}
