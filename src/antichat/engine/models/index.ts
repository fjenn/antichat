/**
 * Model engine (milestone M5): catalogue, device classifier, selection policy
 * and the typed model state the UI draws. The device -> model table is in
 * docs/antichat/m5-device-table.md. `device/probe.ts` (the native read) is
 * imported directly by the adapter, so this barrel stays free of native modules.
 */
export * from './catalog/types';
export {bundledCatalog} from './catalog/bundledCatalog';
export {CatalogError, parseCatalog} from './catalog/parse';
export * from './catalog/lookup';
export * from './catalog/store';
export * from './device/types';
export * from './device/classify';
export * from './device/memory';
export * from './capabilities';
export * from './policy/fit';
export * from './policy/select';
export * from './policy/storeFit';
export * from './policy/download';
export * from './policy/initChain';
export * from './policy/calibration';
export * from './policy/lowMemory';
export * from './state';
export * from './port';
export * from './engine';
export * from './storage';
