import {
  filesFor,
  getClass,
  getModel,
  isRevoked,
  totalBytes,
} from '../catalog/lookup';
import type {
  Catalog,
  CatalogFile,
  CatalogModel,
  DeviceClass,
} from '../catalog/types';
import type {DeviceProfile} from '../device/types';

import {fitModel, FitResult, LoadShape} from './fit';

/**
 * Selection policy: which model this phone gets.
 *
 * Start at the class default and walk down the catalogue ladder until a model
 * fits the measured memory budget. For each model, try the class context
 * first, then smaller contexts, then the same without the vision projector,
 * before giving up on it. The list is never empty: if nothing fits, the
 * smallest model is returned at the smallest context and marked `last_resort`.
 */

export type DemotionReason =
  | 'too_slow'
  | 'low_memory'
  | 'load_failed'
  | 'crashed'
  | 'storage';

/** What this phone has taught us. Persisted by the engine. */
export interface SelectionHistory {
  /** Models that must not be auto-selected again on this phone. */
  demoted?: Record<string, DemotionReason>;
}

export interface SkippedModel {
  modelId: string;
  why: 'revoked' | 'memory' | DemotionReason;
}

export interface ModelChoice {
  model: CatalogModel;
  shape: LoadShape;
  /** Files needed on disk for this choice. */
  files: CatalogFile[];
  downloadBytes: number;
  fit: FitResult;
}

export interface Selection extends ModelChoice {
  deviceClass: DeviceClass;
  reason: 'class_default' | 'upgraded' | 'stepped_down' | 'last_resort';
  /** Larger models that were passed over, in order, with the cause. */
  skipped: SkippedModel[];
  /** A better model the phone can also run; optional download. */
  upgradeOffer?: ModelChoice;
}

/** Context sizes to try, largest first, halving down to the preferred floor. */
export function contextCandidates(
  start: number,
  preferredMin: number,
): number[] {
  const sizes: number[] = [];
  for (let size = start; size >= preferredMin; size = Math.floor(size / 2)) {
    sizes.push(size);
  }
  return sizes.length > 0 ? sizes : [start];
}

/**
 * The best way to load `model` on this phone, or null if no way fits.
 * `strict` allows no compromise: the class context, and vision if wanted.
 */
export function bestShapeFor(
  model: CatalogModel,
  profile: DeviceProfile,
  catalog: Catalog,
  wantVision: boolean,
  strict = false,
): ModelChoice | null {
  const {policy} = catalog;
  const cls = getClass(catalog, profile.deviceClass);
  const start = Math.min(cls.contextSize, model.context.max);
  const contexts = strict
    ? [start]
    : contextCandidates(start, Math.min(policy.preferredMinContextSize, start));
  const backend = profile.gpu.backend;
  const hasProjector = wantVision && model.projector !== undefined;
  const visionOptions = hasProjector
    ? strict
      ? [true]
      : [true, false]
    : [false];
  for (const vision of visionOptions) {
    for (const contextSize of contexts) {
      const choice = choiceFor(
        model,
        {contextSize, vision, backend},
        profile,
        catalog,
      );
      if (choice.fit.fits) {
        return choice;
      }
    }
  }
  return null;
}

function choiceFor(
  model: CatalogModel,
  shape: LoadShape,
  profile: DeviceProfile,
  catalog: Catalog,
): ModelChoice {
  const files = filesFor(model, shape.backend, shape.vision);
  return {
    model,
    shape,
    files,
    downloadBytes: totalBytes(files),
    fit: fitModel(model, shape, profile.budget, catalog.policy),
  };
}

/** The next smaller model on the ladder that holds `modelId`, if any. */
export function stepDown(catalog: Catalog, modelId: string): string | null {
  for (const ladder of [catalog.ladder, catalog.unrestrictedLadder]) {
    const index = ladder.indexOf(modelId);
    if (index >= 0) {
      return ladder[index + 1] ?? null;
    }
  }
  // An alternative model steps down to the default of the class below its own
  // tier, or to the smallest model.
  const model = getModel(catalog, modelId);
  if (!model) {
    return null;
  }
  const ladder = model.unrestricted
    ? catalog.unrestrictedLadder
    : catalog.ladder;
  const smaller = ladder.find(id => {
    const other = getModel(catalog, id);
    return (
      other !== undefined &&
      Math.min(...other.files.map(f => f.sizeBytes)) <
        Math.min(...model.files.map(f => f.sizeBytes))
    );
  });
  return smaller ?? null;
}

function walkLadder(
  ladder: string[],
  startId: string,
  profile: DeviceProfile,
  catalog: Catalog,
  history: SelectionHistory,
  wantVision: boolean,
): {
  choice: ModelChoice | null;
  skipped: SkippedModel[];
  lastUsable: CatalogModel | null;
} {
  const skipped: SkippedModel[] = [];
  let lastUsable: CatalogModel | null = null;
  const start = Math.max(0, ladder.indexOf(startId));
  for (const id of ladder.slice(start)) {
    const model = getModel(catalog, id) as CatalogModel;
    if (isRevoked(catalog, model)) {
      skipped.push({modelId: id, why: 'revoked'});
      continue;
    }
    lastUsable = model;
    const demotion = history.demoted?.[id];
    if (demotion) {
      skipped.push({modelId: id, why: demotion});
      continue;
    }
    const choice = bestShapeFor(model, profile, catalog, wantVision);
    if (choice) {
      return {choice, skipped, lastUsable};
    }
    skipped.push({modelId: id, why: 'memory'});
  }
  return {choice: null, skipped, lastUsable};
}

function upgradeFor(
  profile: DeviceProfile,
  catalog: Catalog,
  history: SelectionHistory,
  wantVision: boolean,
): {choice: ModelChoice; auto: boolean} | null {
  const upgrade = getClass(catalog, profile.deviceClass).upgrade;
  if (!upgrade) {
    return null;
  }
  const model = getModel(catalog, upgrade.modelId) as CatalogModel;
  if (isRevoked(catalog, model) || history.demoted?.[model.id]) {
    return null;
  }
  const floor = upgrade.minMeasuredAvailableBytes?.[profile.budget.platform];
  // The extra floor is about what the phone really has: a floored (assumed)
  // reading does not qualify.
  if (
    floor !== undefined &&
    (profile.budget.source !== 'measured' ||
      profile.budget.availableBytes < floor)
  ) {
    return null;
  }
  // An upgrade must not cost context or vision: it has to fit as the class
  // default would.
  const choice = bestShapeFor(model, profile, catalog, wantVision, true);
  return choice ? {choice, auto: upgrade.mode === 'auto'} : null;
}

export function selectModel(
  profile: DeviceProfile,
  catalog: Catalog,
  history: SelectionHistory = {},
): Selection {
  const cls = getClass(catalog, profile.deviceClass);
  const wantVision = cls.features.vision;
  const {choice, skipped, lastUsable} = walkLadder(
    catalog.ladder,
    cls.defaultModel,
    profile,
    catalog,
    history,
    wantVision,
  );

  if (!choice) {
    return lastResort(profile, catalog, skipped, lastUsable);
  }

  const isDefault = choice.model.id === cls.defaultModel;
  const upgrade = isDefault
    ? upgradeFor(profile, catalog, history, wantVision)
    : null;
  if (upgrade?.auto) {
    return {
      ...upgrade.choice,
      deviceClass: profile.deviceClass,
      reason: 'upgraded',
      skipped,
    };
  }
  return {
    ...choice,
    deviceClass: profile.deviceClass,
    reason: isDefault ? 'class_default' : 'stepped_down',
    skipped,
    upgradeOffer: upgrade?.choice,
  };
}

/** Nothing fits: return the smallest usable model so the app still works. */
function lastResort(
  profile: DeviceProfile,
  catalog: Catalog,
  skipped: SkippedModel[],
  lastUsable: CatalogModel | null,
): Selection {
  const model =
    lastUsable ??
    (getModel(
      catalog,
      catalog.ladder[catalog.ladder.length - 1],
    ) as CatalogModel);
  const shape: LoadShape = {
    contextSize: catalog.policy.minContextSize,
    vision: false,
    backend: profile.gpu.backend,
  };
  return {
    ...choiceFor(model, shape, profile, catalog),
    deviceClass: profile.deviceClass,
    reason: 'last_resort',
    skipped: skipped.filter(s => s.modelId !== model.id),
  };
}

/**
 * The unrestricted add-on for this phone: the class pick, or the next smaller
 * one that fits. Null when none fits; the add-on is optional, so there is no
 * last resort.
 */
export function selectUnrestricted(
  profile: DeviceProfile,
  catalog: Catalog,
  history: SelectionHistory = {},
): ModelChoice | null {
  const cls = getClass(catalog, profile.deviceClass);
  if (cls.unrestrictedModel === null) {
    return null;
  }
  return walkLadder(
    catalog.unrestrictedLadder,
    cls.unrestrictedModel,
    profile,
    catalog,
    history,
    cls.features.vision,
  ).choice;
}
