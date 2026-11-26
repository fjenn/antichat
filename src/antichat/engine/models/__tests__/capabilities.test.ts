import {buildCapabilityMap, CLASS_FEATURES, minClassFor} from '../capabilities';
import {bundledCatalog} from '../catalog/bundledCatalog';
import {getModel} from '../catalog/lookup';
import type {Catalog, CatalogModel} from '../catalog/types';
import type {DeviceProfile} from '../device/types';
import {selectModel} from '../policy/select';

import {PHONE} from './fixtures/devices';

const catalog = bundledCatalog;
const mapFor = (device: DeviceProfile, from: Catalog = catalog) => {
  const selection = selectModel(device, from);
  return buildCapabilityMap(device, from, selection.model, selection.shape);
};
const needs = (minClass: string, marketedRamGb: number) => ({
  available: false,
  reason: {kind: 'needs_class', minClass, marketedRamGb},
});

describe('capability map', () => {
  it('class A: chat, tools and OCR; everything heavy is off with a reason', () => {
    const map = mapFor(PHONE.A());
    expect(map).toMatchObject({
      deviceClass: 'A',
      modelId: 'lfm3-1.7b',
      contextSize: 4096,
      imageInput: 'ocr',
      searchQueriesPerTurn: 1,
      maxTools: 6,
      tools: {available: true},
    });
    expect(map.vision).toEqual(needs('C', 8));
    expect(map.imageGeneration).toEqual(needs('C', 8));
    expect(map.voiceMode).toEqual(needs('B', 6));
    expect(map.embeddings).toEqual(needs('B', 6));
    expect(map.research).toEqual(needs('C', 8));
    expect(map.backgroundMemory).toEqual(needs('B', 6));
  });

  it('class B: voice mode and embeddings beside chat, still no vision', () => {
    const map = mapFor(PHONE.B());
    expect(map.voiceMode).toEqual({available: true});
    expect(map.embeddings).toEqual({available: true});
    expect(map.backgroundMemory).toEqual({available: true});
    expect(map.vision.available).toBe(false);
    expect(map.imageGeneration.available).toBe(false);
    expect(map.contextSize).toBe(8192);
    expect(map.searchQueriesPerTurn).toBe(2);
  });

  it('class C and up: vision, image generation, research', () => {
    for (const phone of [PHONE.C, PHONE.D, PHONE.E]) {
      const map = mapFor(phone());
      expect(map.vision).toEqual({available: true});
      expect(map.imageInput).toBe('model');
      for (const feature of CLASS_FEATURES) {
        expect(map[feature]).toEqual({available: true});
      }
      expect(map.searchQueriesPerTurn).toBe(3);
    }
    expect(mapFor(PHONE.D()).contextSize).toBe(16384);
  });

  it('knows which projectors take audio', () => {
    expect(mapFor(PHONE.C()).audioInput).toEqual({available: true});
    // Qwen3.5 projector is image only.
    expect(mapFor(PHONE.E()).audioInput).toEqual({
      available: false,
      reason: {kind: 'model_lacks'},
    });
    expect(mapFor(PHONE.A()).audioInput).toEqual(needs('C', 8));
  });

  it('follows the model in use, not just the class', () => {
    const device = PHONE.C();
    const lfm = getModel(catalog, 'lfm3-1.7b') as CatalogModel;
    const map = buildCapabilityMap(device, catalog, lfm, {
      contextSize: 8192,
      vision: false,
    });
    expect(map.vision).toEqual({
      available: false,
      reason: {kind: 'model_lacks'},
    });
    expect(map.imageInput).toBe('ocr');
    // Class features are unaffected.
    expect(map.imageGeneration).toEqual({available: true});
  });

  it('reports vision off when the projector was left out to fit', () => {
    const device = PHONE.C();
    const e2b = getModel(catalog, 'gemma-4-e2b-qat') as CatalogModel;
    const map = buildCapabilityMap(device, catalog, e2b, {
      contextSize: 8192,
      vision: false,
    });
    expect(map.vision.available).toBe(false);
  });

  it('describes thinking: optional, or always on for LFM3', () => {
    expect(mapFor(PHONE.C())).toMatchObject({
      thinking: {available: true},
      thinkingAlwaysOn: false,
    });
    expect(mapFor(PHONE.A()).thinkingAlwaysOn).toBe(true);
    const noThinking: CatalogModel = {
      ...(getModel(catalog, 'lfm3-1.7b') as CatalogModel),
      capabilities: {
        tools: false,
        vision: false,
        audio: false,
        thinking: false,
      },
    };
    const map = buildCapabilityMap(PHONE.A(), catalog, noThinking, {
      contextSize: 4096,
      vision: false,
    });
    expect(map.thinking.available).toBe(false);
    expect(map.tools).toEqual({
      available: false,
      reason: {kind: 'model_lacks'},
    });
  });

  it('says "not offered" for a feature no class has', () => {
    const none: Catalog = {
      ...catalog,
      classes: catalog.classes.map(c => ({
        ...c,
        features: {...c.features, imageGeneration: false},
      })),
    };
    expect(minClassFor(none, 'imageGeneration')).toBeNull();
    expect(mapFor(PHONE.E(), none).imageGeneration).toEqual({
      available: false,
      reason: {kind: 'not_offered'},
    });
  });

  it('lists the minimum class for "What this phone can do"', () => {
    expect(minClassFor(catalog, 'imageGeneration')).toEqual({
      minClass: 'C',
      marketedRamGb: 8,
    });
    expect(minClassFor(catalog, 'voiceMode')).toEqual({
      minClass: 'B',
      marketedRamGb: 6,
    });
  });
});
