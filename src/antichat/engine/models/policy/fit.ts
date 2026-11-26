import {weightsFor} from '../catalog/lookup';
import type {Backend, CatalogModel, CatalogPolicy} from '../catalog/types';
import type {MemoryBudget} from '../device/types';

export interface LoadShape {
  contextSize: number;
  /** Load the vision projector too. */
  vision: boolean;
  backend: Backend;
}

export type FitProblem = 'weights' | 'working_memory' | 'below_measured_floor';

export interface FitResult {
  fits: boolean;
  /** Model file plus projector. */
  weightsBytes: number;
  /** KV cache, buffers and projector working memory. */
  dirtyBytes: number;
  problems: FitProblem[];
}

/** Working memory of a model at a context size. */
export function dirtyBytesFor(
  model: CatalogModel,
  shape: Pick<LoadShape, 'contextSize' | 'vision'>,
  policy: CatalogPolicy,
): number {
  return (
    model.memory.kvBytesPerToken * shape.contextSize +
    model.memory.fixedBytes +
    (shape.vision && model.projector ? policy.visionWorkingBytes : 0)
  );
}

export function weightsBytesFor(
  model: CatalogModel,
  shape: Pick<LoadShape, 'vision' | 'backend'>,
): number {
  return (
    weightsFor(model, shape.backend).sizeBytes +
    (shape.vision && model.projector ? model.projector.sizeBytes : 0)
  );
}

/**
 * Does this model, loaded this way, fit the measured budget?
 *
 * iOS checks the two pools separately; Android checks the sum, with the
 * runtime overhead factor, against its single pool. Both also honour the
 * model's own measured-memory floor from the catalogue.
 */
export function fitModel(
  model: CatalogModel,
  shape: LoadShape,
  budget: MemoryBudget,
  policy: CatalogPolicy,
): FitResult {
  const weightsBytes = weightsBytesFor(model, shape);
  const dirtyBytes = dirtyBytesFor(model, shape, policy);
  const problems: FitProblem[] = [];

  if (budget.shared) {
    const needed = (weightsBytes + dirtyBytes) * policy.android.overheadFactor;
    if (needed > budget.weightsPoolBytes) {
      // Say which part is the larger offender, for the capability message.
      problems.push(weightsBytes >= dirtyBytes ? 'weights' : 'working_memory');
    }
  } else {
    if (weightsBytes > budget.weightsPoolBytes) {
      problems.push('weights');
    }
    if (dirtyBytes > budget.dirtyPoolBytes) {
      problems.push('working_memory');
    }
  }
  if (
    budget.availableBytes <
    model.memory.minMeasuredAvailableBytes[budget.platform]
  ) {
    problems.push('below_measured_floor');
  }
  return {fits: problems.length === 0, weightsBytes, dirtyBytes, problems};
}
