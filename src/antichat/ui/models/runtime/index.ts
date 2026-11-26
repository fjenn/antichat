/**
 * The model runtime of this build: M5's real `ModelEngine` on the scripted
 * backend, plus the connectivity port.
 *
 * THE SWAP. When the native half of M5 is merged, `modelRuntime()` returns
 * `createModelRuntime()` from `adapters/model.ts` instead (same `engine`,
 * same `start()`), and `connectivityPort()` returns its `connectivity`. The
 * screens only know `ModelPort` and `Connectivity`.
 */
import AsyncStorage from '@react-native-async-storage/async-storage';
import {Platform} from 'react-native';

import type {Connectivity, ModelPort} from '../../../contracts';
import {
  ModelEngine,
  parseCatalog,
  type CatalogStore,
  type DeviceSnapshot,
} from '../../../engine/models';
import bundledCatalogJson from '../../../engine/models/catalog/bundled.json';
import {ScriptedConnectivity} from './connectivity';
import {Scenario} from './scenario';
import {ScriptedBackend, type ScriptedContext} from './ScriptedBackend';

export interface ScriptedRuntime {
  engine: ModelEngine<ScriptedContext>;
  backend: ScriptedBackend;
  connectivity: ScriptedConnectivity;
  scenario: Scenario;
  /** Read the scenario, start listening to the network, detect the phone. */
  start(): Promise<void>;
  /** Debug: forget every download and every engine decision. */
  reset(): Promise<void>;
}

async function readRealDevice(): Promise<DeviceSnapshot> {
  const {readDeviceSnapshot} = require('../../../engine/models/device/probe');
  return readDeviceSnapshot();
}

async function readRealFreeStorage(): Promise<number> {
  const DeviceInfo = require('react-native-device-info').default;
  return DeviceInfo.getFreeDiskStorage();
}

/**
 * The bundled catalogue, handed to the engine as its catalogue store.
 *
 * Needed in this branch only: the engine imports `./catalog/bundled`, which
 * Metro resolves to `bundled.json` (it tries `.json` before `.ts`), so the
 * engine's own default is undefined on a phone. M5 renames that module in
 * main; with the real runtime this goes away.
 */
const bundledOnly = {
  load: async () => parseCatalog(bundledCatalogJson),
} as unknown as CatalogStore;

const ENGINE_KEYS = [
  'antichat.models.history',
  'antichat.models.load.pending',
  'antichat.models.load.crashes',
];

export function createScriptedRuntime(): ScriptedRuntime {
  const scenario = new Scenario();
  const connectivity = new ScriptedConnectivity(scenario);
  const backend = new ScriptedBackend({
    storage: AsyncStorage,
    scenario,
    network: () => connectivity.status,
    readRealDevice,
    readRealFreeStorage,
    platform: Platform.OS === 'ios' ? 'ios' : 'android',
  });
  const engine = new ModelEngine<ScriptedContext>({
    backend,
    storage: AsyncStorage,
    catalogStore: bundledOnly,
  });
  let starting: Promise<void> | null = null;

  connectivity.subscribe(() => {
    if (!connectivity.online) {
      backend.connectionLost();
    }
    if (engine.phase === 'ready') {
      engine.onNetworkChange().catch(() => undefined);
    }
  });

  return {
    engine,
    backend,
    connectivity,
    scenario,
    start: () => {
      starting ??= (async () => {
        await scenario.load();
        await connectivity.start().catch(() => undefined);
        await engine.initialize();
      })();
      return starting;
    },
    reset: async () => {
      await backend.wipe();
      await Promise.all(ENGINE_KEYS.map(key => AsyncStorage.removeItem(key)));
    },
  };
}

let shared: ScriptedRuntime | null = null;

/** The app's model runtime. Built on first use. */
export function modelRuntime(): ScriptedRuntime {
  shared ??= createScriptedRuntime();
  return shared;
}

/** For `adapters/index.ts`. */
export function modelPort(): ModelPort {
  return modelRuntime().engine as unknown as ModelPort;
}

export function connectivityPort(): Connectivity {
  return modelRuntime().connectivity;
}

/** Tests: drop the shared runtime. */
export function resetModelRuntime(): void {
  shared = null;
}

export {Scenario, ScriptedBackend, ScriptedConnectivity};
export * from './scenario';
