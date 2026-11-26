/**
 * Model families whose chat templates differ in ways the prompt engine has to
 * know about. Facts below were read from the GGUF templates of
 * gemma-4-E2B-it-qat, Qwen3.5-0.8B/2B and LFM3-1.7B (llama.cpp b12359,
 * 2026-11-24); see docs/antichat/m7-prompt-eval.md.
 */

export type ModelFamily = 'gemma4' | 'qwen35' | 'lfm3' | 'generic';

export interface SamplingPreset {
  temperature?: number;
  top_p?: number;
  top_k?: number;
  min_p?: number;
  penalty_repeat?: number;
}

export interface FamilyProfile {
  id: ModelFamily;
  /** What the template does when `enable_thinking` is not passed. */
  thinkingDefault: boolean;
  /**
   * Where the template writes the thinking switch. `prefix` means toggling
   * thinking rewrites the first tokens of the prompt and the whole KV cache is
   * lost (Gemma 4 puts `<|think|>` at the top of the system turn); `suffix`
   * means only the generation prompt changes.
   */
  thinkingSwitch: 'prefix' | 'suffix' | 'none';
  /**
   * Qwen3.5 renders the tool list BEFORE the system text, so any change to
   * the tool set invalidates the cached system prompt. The others render the
   * system text first.
   */
  toolsBeforeSystem: boolean;
  /** Fallback characters per token when no tokeniser is available. */
  charsPerToken: number;
  /** Vendor-recommended sampling with thinking off / on. */
  sampling: SamplingPreset;
  samplingThinking: SamplingPreset;
  /**
   * How to ask for a chat title. `inline` asks as one more turn of the chat,
   * which keeps the KV cache; `standalone` is a separate prompt that costs a
   * re-evaluation of the first exchange on turn 2. Measured: Gemma 4 E2B and
   * LFM3 title equally well inline; Qwen3.5-0.8B drifts to English inline.
   */
  titleMode: 'inline' | 'standalone';
  /** Extra stable system-prompt line for this family, measured to help. */
  systemAddendum?: string;
}

const PROFILES: Record<ModelFamily, FamilyProfile> = {
  gemma4: {
    id: 'gemma4',
    thinkingDefault: false,
    thinkingSwitch: 'prefix',
    toolsBeforeSystem: false,
    charsPerToken: 3.6,
    sampling: {temperature: 1.0, top_p: 0.95, top_k: 64},
    titleMode: 'inline',
    samplingThinking: {temperature: 1.0, top_p: 0.95, top_k: 64},
  },
  qwen35: {
    id: 'qwen35',
    thinkingDefault: false,
    thinkingSwitch: 'suffix',
    toolsBeforeSystem: true,
    charsPerToken: 3.4,
    sampling: {temperature: 0.7, top_p: 0.8, top_k: 20},
    titleMode: 'standalone',
    samplingThinking: {temperature: 0.6, top_p: 0.95, top_k: 20},
  },
  lfm3: {
    id: 'lfm3',
    // The template defaults to thinking ON; it must be switched off
    // explicitly on every request.
    thinkingDefault: true,
    thinkingSwitch: 'suffix',
    toolsBeforeSystem: false,
    charsPerToken: 3.5,
    sampling: {temperature: 0.3, min_p: 0.15, penalty_repeat: 1.05},
    titleMode: 'inline',
    samplingThinking: {temperature: 0.3, min_p: 0.15, penalty_repeat: 1.05},
  },
  generic: {
    id: 'generic',
    thinkingDefault: false,
    thinkingSwitch: 'none',
    toolsBeforeSystem: false,
    charsPerToken: 3.3,
    sampling: {},
    titleMode: 'standalone',
    samplingThinking: {},
  },
};

export interface ModelIdentity {
  name?: string | null;
  filename?: string | null;
  id?: string | null;
  /** Raw Jinja template, when the caller has it. */
  chatTemplate?: string | null;
}

/** Family of a model from its names, falling back to template fingerprints. */
export function detectModelFamily(model?: ModelIdentity | null): ModelFamily {
  if (!model) {
    return 'generic';
  }
  const label = [model.name, model.filename, model.id]
    .filter(Boolean)
    .join(' ')
    .toLowerCase();
  if (/gemma[-_ ]?(?:4|3n)/.test(label)) {
    return 'gemma4';
  }
  if (/lfm[-_ ]?[23]/.test(label)) {
    return 'lfm3';
  }
  if (/qwen[-_ ]?3/.test(label)) {
    return 'qwen35';
  }
  const template = model.chatTemplate ?? '';
  if (template.includes('<|turn>')) {
    return 'gemma4';
  }
  if (template.includes('<additional_tools>')) {
    return 'lfm3';
  }
  if (
    template.includes('<|im_start|>') &&
    template.includes('enable_thinking')
  ) {
    return 'qwen35';
  }
  return 'generic';
}

export function familyProfile(family: ModelFamily): FamilyProfile {
  return PROFILES[family] ?? PROFILES.generic;
}

/** Vendor sampling for a family, for callers that let the engine choose. */
export function samplingFor(
  family: ModelFamily,
  thinking: boolean,
): SamplingPreset {
  const profile = familyProfile(family);
  return {...(thinking ? profile.samplingThinking : profile.sampling)};
}
