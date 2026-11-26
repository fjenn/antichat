import type {Catalog} from '../catalog/types';

import {stepDown} from './select';

/**
 * What to do when the OS reports memory pressure. Pure: returns the actions,
 * in order; the engine carries them out.
 *
 * Order of sacrifice: helper models first (image generation, voice,
 * embeddings), then the vision projector, then the chat model itself. A chat
 * model that has to be dropped twice within the window is too big for how this
 * phone is used, so the phone moves to the smaller model and says so in chat.
 */

export type MemoryPressure = 'warning' | 'critical';

export type AuxModel = 'imageGeneration' | 'voice' | 'embeddings';

export interface LowMemoryContext {
  level: MemoryPressure;
  /** Null when no chat model is loaded. */
  loadedModelId: string | null;
  projectorLoaded: boolean;
  generating: boolean;
  /** Helper models in memory right now. */
  aux: AuxModel[];
  /** Times (ms) of earlier critical events that released the chat model. */
  recentReleases: number[];
  now: number;
}

export type LowMemoryAction =
  | {type: 'release_aux'; which: AuxModel}
  | {type: 'release_projector'}
  /** `after_generation`: let the current answer finish first. */
  | {type: 'release_model'; when: 'now' | 'after_generation'}
  | {type: 'demote'; from: string; to: string; notice: 'low_memory_switched'};

/** Two forced releases inside this window trigger the switch to a smaller model. */
export const DEMOTION_WINDOW_MS = 10 * 60 * 1000;

const AUX_ORDER: AuxModel[] = ['imageGeneration', 'voice', 'embeddings'];

export function reactToLowMemory(
  context: LowMemoryContext,
  catalog: Catalog,
): LowMemoryAction[] {
  const actions: LowMemoryAction[] = AUX_ORDER.filter(which =>
    context.aux.includes(which),
  ).map(which => ({type: 'release_aux', which}));

  if (context.level === 'warning') {
    // A warning costs the user nothing visible: helpers go, and the projector
    // only if there was no helper to give up.
    if (
      actions.length === 0 &&
      context.projectorLoaded &&
      !context.generating
    ) {
      actions.push({type: 'release_projector'});
    }
    return actions;
  }

  if (context.loadedModelId === null) {
    return actions;
  }
  if (context.projectorLoaded) {
    actions.push({type: 'release_projector'});
  }
  actions.push({
    type: 'release_model',
    when: context.generating ? 'after_generation' : 'now',
  });

  const earlier = context.recentReleases.filter(
    at => context.now - at <= DEMOTION_WINDOW_MS,
  );
  const smaller = stepDown(catalog, context.loadedModelId);
  if (earlier.length >= 1 && smaller !== null) {
    actions.push({
      type: 'demote',
      from: context.loadedModelId,
      to: smaller,
      notice: 'low_memory_switched',
    });
  }
  return actions;
}
