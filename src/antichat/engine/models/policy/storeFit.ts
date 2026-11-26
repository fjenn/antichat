import {getClass} from '../catalog/lookup';
import {
  DEVICE_CLASSES,
  type Catalog,
  type CatalogModel,
  type DeviceClass,
} from '../catalog/types';
import type {DeviceProfile} from '../device/types';

import type {ModelChoice} from './select';

/**
 * How well a model runs on this phone, for the model store. Worked out from
 * the same measured memory budget as the automatic pick, never from the
 * marketed RAM.
 *
 * - `great`: loads with a full chat memory (the model's default context,
 *   or the class's if smaller) and is sized for this class or a smaller one.
 * - `ok`: loads, but only with a shorter context, or it is sized for a
 *   bigger phone and will be slower.
 * - `too_large`: does not load within the budget (or is an unrestricted
 *   model on a class that gets none).
 */
export type StoreFitLevel = 'great' | 'ok' | 'too_large';

export interface StoreFit {
  level: StoreFitLevel;
  /** For `too_large`: the marketed memory of a phone that runs it. */
  needsRamGb?: number;
}

const index = (cls: DeviceClass) => DEVICE_CLASSES.indexOf(cls);

function marketedRam(catalog: Catalog, cls: DeviceClass): number {
  return getClass(catalog, cls).marketedRamGb;
}

/** The smallest class above `from` (or at `atLeast`) a model would need. */
function neededRam(
  catalog: Catalog,
  from: DeviceClass,
  atLeast: DeviceClass,
): number {
  const next = Math.min(
    Math.max(index(atLeast), index(from) + 1),
    DEVICE_CLASSES.length - 1,
  );
  return marketedRam(catalog, DEVICE_CLASSES[next]);
}

export function storeFit(
  model: CatalogModel,
  profile: DeviceProfile,
  catalog: Catalog,
  /** The way the engine would load it, or null when nothing fits. */
  choice: ModelChoice | null,
): StoreFit {
  const cls = getClass(catalog, profile.deviceClass);
  if (model.unrestricted && cls.unrestrictedModel === null) {
    // Unrestricted models start at the first class that has one.
    const first =
      catalog.classes.find(c => c.unrestrictedModel !== null)?.id ??
      DEVICE_CLASSES[DEVICE_CLASSES.length - 1];
    const atLeast = index(model.tier) > index(first) ? model.tier : first;
    return {
      level: 'too_large',
      needsRamGb: neededRam(catalog, profile.deviceClass, atLeast),
    };
  }
  if (!choice || !choice.fit.fits) {
    return {
      level: 'too_large',
      needsRamGb: neededRam(catalog, profile.deviceClass, model.tier),
    };
  }
  // A full chat memory: the model's own default context, or the class's
  // when that is smaller.
  const fullContext =
    choice.shape.contextSize >=
    Math.min(model.context.default, cls.contextSize);
  const sizedForThisPhone = index(model.tier) <= index(profile.deviceClass);
  return {level: fullContext && sizedForThisPhone ? 'great' : 'ok'};
}
