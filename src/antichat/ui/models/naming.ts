/**
 * Plain names for models. People choose between "Smart" and "Fast"; the real
 * model name ("Gemma 4 E4B") is only shown under Details.
 *
 * The roles are worked out from what the engine publishes for this phone, so
 * a catalogue update needs no change here.
 */
import type {ModelPort, ModelView} from '../../contracts';

export type ModelRole =
  | 'smart'
  | 'fast'
  | 'smartest'
  | 'unrestricted'
  | 'other';

export interface ModelLineup {
  /** The model the app picked for this phone. */
  smart?: ModelView;
  /** A clearly smaller, quicker model. */
  fast?: ModelView;
  /** A larger model the phone can run, more slowly. */
  smartest?: ModelView;
  /** The optional add-on without refusal training. */
  unrestricted?: ModelView;
  /** Everything else the phone could run; shown to experts only. */
  others: ModelView[];
}

/** A quicker model must be clearly smaller to be worth offering. */
const FAST_MAX_SHARE = 0.75;
const LARGER_MIN_SHARE = 1.1;

export function lineup(
  port: Pick<ModelPort, 'models' | 'unrestrictedModelId'>,
): ModelLineup {
  const supported = port.models.filter(model => model.supported);
  const standard = supported.filter(model => !model.unrestricted);
  const smart = standard.find(model => model.recommended);
  const bySize = [...standard].sort(
    (a, b) => a.downloadBytes - b.downloadBytes,
  );
  let fast: ModelView | undefined;
  let smartest: ModelView | undefined;
  if (smart) {
    // Measured models (the catalogue ladder) get the plain names; store
    // extras keep their own. Older views without the flag all count.
    const named = bySize.filter(model => model.measured !== false);
    fast = named
      .filter(
        model =>
          model.id !== smart.id &&
          model.downloadBytes <= smart.downloadBytes * FAST_MAX_SHARE,
      )
      .pop();
    const larger = named.filter(
      model =>
        model.id !== smart.id &&
        model.downloadBytes >= smart.downloadBytes * LARGER_MIN_SHARE,
    );
    // The biggest measured model this phone runs; else the next larger one.
    smartest =
      larger.filter(model => model.measured === true).pop() ?? larger[0];
  }
  const unrestricted = supported.find(
    model => model.id === port.unrestrictedModelId,
  );
  const named = new Set(
    [smart, fast, smartest, unrestricted]
      .filter((model): model is ModelView => Boolean(model))
      .map(model => model.id),
  );
  return {
    smart,
    fast,
    smartest,
    unrestricted,
    others: supported.filter(model => !named.has(model.id)),
  };
}

export function roleOf(modelId: string, models: ModelLineup): ModelRole {
  if (models.smart?.id === modelId) {
    return 'smart';
  }
  if (models.fast?.id === modelId) {
    return 'fast';
  }
  if (models.smartest?.id === modelId) {
    return 'smartest';
  }
  if (models.unrestricted?.id === modelId) {
    return 'unrestricted';
  }
  return 'other';
}

/** A model that is on the phone (possibly in use). */
export function isInstalled(model: ModelView): boolean {
  const status = model.state.status;
  return (
    status === 'ready' ||
    status === 'loading' ||
    status === 'loaded' ||
    (status === 'failed' && model.state.resumeTo === 'ready')
  );
}

/** A download exists for it: running, paused or being checked. */
export function isArriving(model: ModelView): boolean {
  return (
    model.state.status === 'downloading' || model.state.status === 'verifying'
  );
}

export type FitLevel = 'great' | 'ok' | 'too_large';

/** How well a model runs here; older fakes without `fit` fall back on `supported`. */
export function fitOf(model: ModelView): FitLevel {
  return model.fit ?? (model.supported ? 'great' : 'too_large');
}

export interface StoreSections {
  /** The app's pick for this phone. */
  recommended: ModelView[];
  /** Smaller than the pick: quicker answers. Nearest first. */
  faster: ModelView[];
  /** Larger than the pick: better answers, slower. Nearest first. */
  smarter: ModelView[];
  /** Models without refusal training, smallest first. */
  unrestricted: ModelView[];
}

/**
 * The model store's sections: every catalogue model this phone can run (and
 * anything already on it). Size stands in for speed: on a phone a smaller file is a quicker
 * model.
 */
export function storeSections(port: Pick<ModelPort, 'models'>): StoreSections {
  // Held-back models (a known problem) and models this phone cannot run stay
  // out unless already here: the bigger the phone, the more it is offered.
  const all = port.models.filter(
    model =>
      (!model.heldBack && fitOf(model) !== 'too_large') ||
      isInstalled(model) ||
      isArriving(model),
  );
  const pick = all.find(model => model.recommended && !model.unrestricted);
  const size = (model: ModelView) => model.weightsBytes ?? model.downloadBytes;
  const pickBytes = pick ? size(pick) : 0;
  const standard = all.filter(
    model => !model.unrestricted && model.id !== pick?.id,
  );
  const bySize = (a: ModelView, b: ModelView) => size(a) - size(b);
  return {
    recommended: pick ? [pick] : [],
    faster: standard
      .filter(model => pick && size(model) < pickBytes)
      .sort((a, b) => bySize(b, a)),
    smarter: standard
      .filter(model => !pick || size(model) >= pickBytes)
      .sort(bySize),
    unrestricted: all.filter(model => model.unrestricted).sort(bySize),
  };
}

export interface UnrestrictedPair {
  /** The model in use. */
  active: ModelView;
  /** The other side of the switch: the unrestricted model of the same size, or its standard base. */
  target: ModelView;
  /** The model in use is the unrestricted one. */
  on: boolean;
}

/**
 * The unrestricted counterpart of the model in use (same size, from the
 * catalogue's `baseModel`), or the standard model an unrestricted one comes
 * from. Null when there is no counterpart this phone can run.
 */
export function unrestrictedPair(
  models: ModelView[],
  activeId: string | null | undefined,
): UnrestrictedPair | null {
  const active = models.find(model => model.id === activeId);
  if (!active) {
    return null;
  }
  if (active.unrestricted) {
    const base = models.find(model => model.id === active.baseModel);
    return base ? {active, target: base, on: true} : null;
  }
  const target = models.find(
    model =>
      model.unrestricted &&
      model.baseModel === active.id &&
      (fitOf(model) !== 'too_large' || isInstalled(model)),
  );
  return target ? {active, target, on: false} : null;
}
