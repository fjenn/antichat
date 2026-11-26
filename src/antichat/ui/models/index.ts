/**
 * Models: the top-bar menu contents, "Manage models", "What this phone can
 * do" and Storage. Screens read `ModelPort`; `modelCoordinator()` decides
 * when things are downloaded and loaded.
 */
export {
  modelCoordinator,
  onFirstModelReady,
  setModelCoordinator,
} from './shared';
export {ModelCoordinator} from './coordinator';
export {ModelPrefs} from './modelPrefs';
export * from './format';
export * from './naming';
export * from './setupStatus';
export {useModels, useSetupStatus, useChatReady} from './hooks';
export {
  ModelMenuButton,
  plainName,
  tagline,
  useModelMenu,
  type ModelMenuButtonProps,
  type ModelMenuState,
} from './ModelMenu';
export {ModelDetailsSheet} from './ModelDetailsSheet';
export {phoneName} from './phoneName';
export {ManageModelsScreen} from './ManageModelsScreen';
export {PhoneCapabilitiesScreen} from './PhoneCapabilitiesScreen';
export {StorageScreen} from './StorageScreen';
export {capabilityLines, type CapabilityLine} from './capabilityList';
export {
  storageBreakdown,
  type StorageBreakdown,
  type StorageProbe,
} from './storage';
