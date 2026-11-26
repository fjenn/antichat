import {getClass} from './catalog/lookup';
import type {
  Catalog,
  CatalogModel,
  ClassFeatures,
  DeviceClass,
} from './catalog/types';
import {classIndex} from './device/classify';
import type {DeviceProfile} from './device/types';
import type {LoadShape} from './policy/fit';

/**
 * Capability map: what this phone can do, as data for the UI.
 *
 * Rule from the product spec: an unavailable feature is hidden, not shown
 * disabled, except on "What this phone can do", which lists every feature with
 * the reason it is missing. The reason is structured so the UI words it.
 */

export type CapabilityReason =
  /** The phone is below the class the feature needs. */
  | {kind: 'needs_class'; minClass: DeviceClass; marketedRamGb: number}
  /** The phone could, but the model in use cannot (e.g. no projector). */
  | {kind: 'model_lacks'}
  | {kind: 'not_offered'};

export interface Capability {
  available: boolean;
  reason?: CapabilityReason;
}

export type ClassFeature = Exclude<
  keyof ClassFeatures,
  'searchQueriesPerTurn' | 'maxTools'
>;

export const CLASS_FEATURES: ClassFeature[] = [
  'vision',
  'imageGeneration',
  'voiceMode',
  'embeddings',
  'research',
  'followUps',
  'renderHtml',
  'backgroundMemory',
];

export interface CapabilityMap {
  deviceClass: DeviceClass;
  modelId: string;
  contextSize: number;
  /** The model answers about images itself. */
  vision: Capability;
  /** How a photo is read: by the model, or by on-device text recognition. */
  imageInput: 'model' | 'ocr';
  /** Audio clips as model input (Gemma 4 projector). */
  audioInput: Capability;
  imageGeneration: Capability;
  /** Hands-free voice conversation. Dictation and read-aloud work everywhere. */
  voiceMode: Capability;
  /** Embedding model loaded beside the chat model (else keyword search only). */
  embeddings: Capability;
  research: Capability;
  followUps: Capability;
  renderHtml: Capability;
  backgroundMemory: Capability;
  tools: Capability;
  /** A "think longer" switch exists for this model. */
  thinking: Capability;
  /** The model cannot switch thinking off reliably. */
  thinkingAlwaysOn: boolean;
  searchQueriesPerTurn: number;
  maxTools: number;
}

/** The lowest class that has a feature, or null if no class has it. */
export function minClassFor(
  catalog: Catalog,
  feature: ClassFeature,
): {minClass: DeviceClass; marketedRamGb: number} | null {
  const cls = catalog.classes.find(c => c.features[feature]);
  return cls ? {minClass: cls.id, marketedRamGb: cls.marketedRamGb} : null;
}

function classCapability(
  catalog: Catalog,
  deviceClass: DeviceClass,
  feature: ClassFeature,
): Capability {
  if (getClass(catalog, deviceClass).features[feature]) {
    return {available: true};
  }
  const min = minClassFor(catalog, feature);
  return {
    available: false,
    reason:
      min !== null && classIndex(min.minClass) > classIndex(deviceClass)
        ? {kind: 'needs_class', ...min}
        : {kind: 'not_offered'},
  };
}

const modelCapability = (has: boolean): Capability =>
  has ? {available: true} : {available: false, reason: {kind: 'model_lacks'}};

export function buildCapabilityMap(
  profile: DeviceProfile,
  catalog: Catalog,
  model: CatalogModel,
  shape: Pick<LoadShape, 'contextSize' | 'vision'>,
): CapabilityMap {
  const cls = getClass(catalog, profile.deviceClass);
  const feature = (name: ClassFeature) =>
    classCapability(catalog, profile.deviceClass, name);

  const classVision = feature('vision');
  const vision: Capability = !classVision.available
    ? classVision
    : modelCapability(shape.vision && model.capabilities.vision);
  const hasAudio =
    shape.vision && (model.projector?.modalities.includes('audio') ?? false);

  return {
    deviceClass: profile.deviceClass,
    modelId: model.id,
    contextSize: shape.contextSize,
    vision,
    imageInput: vision.available ? 'model' : 'ocr',
    audioInput: !classVision.available
      ? classVision
      : modelCapability(hasAudio),
    imageGeneration: feature('imageGeneration'),
    voiceMode: feature('voiceMode'),
    embeddings: feature('embeddings'),
    research: feature('research'),
    followUps: feature('followUps'),
    renderHtml: feature('renderHtml'),
    backgroundMemory: feature('backgroundMemory'),
    tools: modelCapability(model.capabilities.tools),
    thinking: modelCapability(
      model.capabilities.thinking && model.template.thinking.supported,
    ),
    thinkingAlwaysOn:
      model.template.thinking.supported && !model.template.thinking.canDisable,
    searchQueriesPerTurn: cls.features.searchQueriesPerTurn,
    maxTools: cls.features.maxTools,
  };
}
