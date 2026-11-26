import '../../../testing/setup';

import AsyncStorage from '@react-native-async-storage/async-storage';

import {FakeConnectivity} from '../../../contracts/fakes';
import type {ModelPort} from '../../../contracts';
import {MemoryStorage, ModelEngine} from '../../../engine/models';
import {ModelCoordinator} from '../coordinator';
import {ModelPrefs} from '../modelPrefs';
import {Scenario} from '../runtime/scenario';
import {ScriptedBackend} from '../runtime/ScriptedBackend';
import {isInstalled} from '../naming';

const GB = 1000 ** 3;

interface Rig {
  engine: ModelEngine;
  port: ModelPort;
  backend: ScriptedBackend;
  scenario: Scenario;
  connectivity: FakeConnectivity;
  coordinator: ModelCoordinator;
  storage: MemoryStorage;
  ready: jest.Mock;
}

/** A whole app start on a pretend phone; `storage` carries over a restart. */
function rig(
  options: {
    storage?: MemoryStorage;
    bytesPerSecond?: number;
    device?: Scenario['device'];
    scenario?: Scenario;
    connectivity?: FakeConnectivity;
  } = {},
): Rig {
  const storage = options.storage ?? new MemoryStorage();
  const scenario = options.scenario ?? new Scenario();
  scenario.device = options.device ?? scenario.device;
  if (scenario.device === 'real') {
    scenario.device = 'large';
  }
  const connectivity = options.connectivity ?? new FakeConnectivity();
  const backend = new ScriptedBackend({
    storage,
    scenario,
    network: () => ({
      online: connectivity.online,
      metered: connectivity.metered,
    }),
    tickMs: 5,
    timeScale: 0.01,
    bytesPerSecond: options.bytesPerSecond ?? 400 * GB,
  });
  const engine = new ModelEngine({backend, storage});
  const port = engine as unknown as ModelPort;
  connectivity.subscribe(() => {
    if (!connectivity.online) {
      backend.connectionLost();
    }
    if (engine.phase === 'ready') {
      engine.onNetworkChange().catch(() => undefined);
    }
  });
  const ready = jest.fn();
  const coordinator = new ModelCoordinator({
    model: port,
    connectivity,
    prefs: new ModelPrefs(),
    onReady: ready,
  });
  return {
    engine,
    port,
    backend,
    scenario,
    connectivity,
    coordinator,
    storage,
    ready,
  };
}

async function until(check: () => boolean, ms = 4000): Promise<void> {
  const end = Date.now() + ms;
  while (!check()) {
    if (Date.now() > end) {
      throw new Error('timed out waiting');
    }
    await new Promise(resolve => setTimeout(resolve, 5));
  }
}

const kind = (r: Rig) => r.coordinator.status().kind;

describe('first run on the scripted backend', () => {
  const rigs: Rig[] = [];
  const start = (options?: Parameters<typeof rig>[0]) => {
    const made = rig(options);
    rigs.push(made);
    return made;
  };

  beforeEach(() => AsyncStorage.clear());
  afterEach(() => {
    rigs.splice(0).forEach(made => made.coordinator.dispose());
  });

  it('shows nothing before "Get started" and downloads nothing', async () => {
    const r = start();
    await r.coordinator.boot();
    expect(kind(r)).toBe('hidden');
    expect(r.port.models.some(isInstalled)).toBe(false);
    expect(await r.backend.usedBytes()).toBe(0);
  });

  it('goes from "Get started" to a loaded model with no other call', async () => {
    const r = start();
    await r.coordinator.boot();
    r.coordinator.getStarted();
    expect(['preparing', 'downloading']).toContain(kind(r));
    await until(() => r.coordinator.chatReady);
    expect(r.port.activeModelId).toBe(r.port.recommendedModelId);
    // The completion moment shows once, then the card goes away.
    expect(kind(r)).toBe('ready');
    expect(r.ready).toHaveBeenCalledTimes(1);
    r.coordinator.endCelebration();
    expect(kind(r)).toBe('hidden');
    expect(r.coordinator.prefs.celebrated).toBe(true);
  });

  it('picks the model for the phone: a small phone gets the small one', async () => {
    const small = start({device: 'small'});
    const large = start({device: 'large'});
    await Promise.all([small.coordinator.boot(), large.coordinator.boot()]);
    expect(small.port.deviceClass).toBe('A');
    expect(large.port.deviceClass).toBe('D');
    expect(small.coordinator.target()!.downloadBytes).toBeLessThan(
      large.coordinator.target()!.downloadBytes,
    );
  });

  it('pauses and resumes from the same byte', async () => {
    const r = start({bytesPerSecond: 2 * GB});
    await r.coordinator.boot();
    r.coordinator.getStarted();
    await until(() => kind(r) === 'downloading');
    r.coordinator.pause();
    const paused = r.coordinator.status();
    expect(paused.kind).toBe('paused');
    if (paused.kind !== 'paused') {
      return;
    }
    expect(paused.reason).toBe('user');
    await new Promise(resolve => setTimeout(resolve, 40));
    const later = r.coordinator.status();
    expect(later.kind === 'paused' && later.receivedBytes).toBe(
      paused.receivedBytes,
    );
    r.coordinator.resume();
    await until(() => kind(r) === 'downloading');
    const resumed = r.coordinator.status();
    expect(
      resumed.kind === 'downloading' && resumed.receivedBytes,
    ).toBeGreaterThanOrEqual(paused.receivedBytes);
  });

  it('continues an interrupted download after a restart', async () => {
    const storage = new MemoryStorage();
    const first = start({storage, bytesPerSecond: 3 * GB});
    await first.coordinator.boot();
    first.coordinator.getStarted();
    await until(() => {
      const status = first.coordinator.status();
      return status.kind === 'downloading' && status.fraction > 0.1;
    });
    const before = await first.backend.usedBytes();
    first.coordinator.dispose();
    // "Kill" the app: stop the running download without telling the engine.
    first.backend.connectionLost();

    const second = start({storage});
    await second.coordinator.boot();
    expect(second.coordinator.prefs.started).toBe(true);
    expect(await second.backend.usedBytes()).toBeGreaterThanOrEqual(
      before * 0.9,
    );
    await until(() => second.coordinator.chatReady);
  });

  it('stays paused across a restart when the user paused', async () => {
    const storage = new MemoryStorage();
    const first = start({storage, bytesPerSecond: 3 * GB, device: 'small'});
    await first.coordinator.boot();
    first.coordinator.getStarted();
    await until(() => kind(first) === 'downloading');
    first.coordinator.pause();
    first.coordinator.dispose();

    const second = start({storage, bytesPerSecond: 3 * GB, device: 'small'});
    await second.coordinator.boot();
    await until(() => kind(second) === 'paused');
    await new Promise(resolve => setTimeout(resolve, 30));
    expect(kind(second)).toBe('paused');
    second.coordinator.resume();
    await until(() => second.coordinator.chatReady);
  });

  it('asks once on mobile data and can wait for Wi-Fi', async () => {
    const connectivity = new FakeConnectivity();
    connectivity.set(true, true);
    const r = start({connectivity});
    await r.coordinator.boot();
    r.coordinator.getStarted();
    await until(() => kind(r) === 'confirm_metered');
    const question = r.coordinator.status();
    expect(question.kind === 'confirm_metered' && question.bytes).toBe(
      r.coordinator.target()!.downloadBytes,
    );

    r.coordinator.waitForWifi();
    await until(() => kind(r) === 'waiting_wifi');
    expect(await r.backend.usedBytes()).toBe(0);

    // Wi-Fi arrives: the download starts by itself.
    connectivity.set(true, false);
    await until(() => r.coordinator.chatReady);
  });

  it('downloads on mobile data when the user says so', async () => {
    const connectivity = new FakeConnectivity();
    connectivity.set(true, true);
    const r = start({connectivity});
    await r.coordinator.boot();
    r.coordinator.getStarted();
    await until(() => kind(r) === 'confirm_metered');
    r.coordinator.useMobileData();
    await until(() => r.coordinator.chatReady);
  });

  it('waits when the connection drops and carries on when it returns', async () => {
    const r = start({bytesPerSecond: 3 * GB, device: 'small'});
    await r.coordinator.boot();
    r.coordinator.getStarted();
    await until(() => kind(r) === 'downloading');
    r.connectivity.set(false);
    await until(() => kind(r) === 'paused');
    const paused = r.coordinator.status();
    expect(paused.kind === 'paused' && paused.reason).toBe('offline');
    r.connectivity.set(true);
    await until(() => r.coordinator.chatReady, 8000);
  });

  it('uses a smaller model when storage is tight, and says why', async () => {
    const scenario = new Scenario();
    scenario.storage = 'tight';
    const r = start({scenario, device: 'large'});
    await r.coordinator.boot();
    const wanted = r.port.recommendedModelId;
    r.coordinator.getStarted();
    await until(() => r.coordinator.chatReady);
    expect(r.port.activeModelId).not.toBe(wanted);
    expect(r.port.notices.some(n => n.kind === 'storage_limited')).toBe(true);
  });

  it('stops with a clear state when the phone is full, and recovers', async () => {
    const scenario = new Scenario();
    scenario.storage = 'full';
    const r = start({scenario, device: 'small'});
    await r.coordinator.boot();
    r.coordinator.getStarted();
    await until(() => kind(r) === 'failed');
    const failed = r.coordinator.status();
    expect(failed.kind === 'failed' && failed.reason).toBe('storage_full');
    expect(failed.kind === 'failed' && failed.neededBytes).toBeGreaterThan(0);

    scenario.storage = 'real';
    r.coordinator.retry();
    await until(() => r.coordinator.chatReady);
  });

  it('recovers from one broken transfer by itself, keeping the bytes', async () => {
    const scenario = new Scenario();
    scenario.failure = 'network';
    const r = start({scenario, bytesPerSecond: 20 * GB});
    await r.coordinator.boot();
    r.coordinator.getStarted();
    // The engine restarts a broken transfer from the bytes on disk (twice at
    // most) before it shows "failed" with a retry button.
    let sawFailed = false;
    const off = r.port.subscribe(() => {
      sawFailed = sawFailed || kind(r) === 'failed';
    });
    await until(() => r.coordinator.chatReady);
    off();
    expect(sawFailed).toBe(false);
  });

  it('downloads again when the file fails its check', async () => {
    const scenario = new Scenario();
    scenario.failure = 'checksum';
    const r = start({scenario});
    await r.coordinator.boot();
    r.coordinator.getStarted();
    await until(() => kind(r) === 'failed');
    const failed = r.coordinator.status();
    expect(failed.kind === 'failed' && failed.reason).toBe('checksum_mismatch');
    r.coordinator.retry();
    await until(() => r.coordinator.chatReady);
  });

  it('falls back to a smaller model when the chosen one will not load', async () => {
    const scenario = new Scenario();
    scenario.failure = 'load';
    const r = start({scenario, device: 'large'});
    await r.coordinator.boot();
    const wanted = r.port.recommendedModelId;
    r.coordinator.getStarted();
    await until(() => r.coordinator.chatReady, 8000);
    expect(r.port.activeModelId).not.toBe(wanted);
    expect(r.port.notices.some(n => n.kind === 'load_fell_back')).toBe(true);
  });

  it('loads the installed model again after a restart', async () => {
    const storage = new MemoryStorage();
    const first = start({storage});
    await first.coordinator.boot();
    first.coordinator.getStarted();
    await until(() => first.coordinator.chatReady);
    const modelId = first.port.activeModelId;
    first.coordinator.dispose();

    const second = start({storage});
    await second.coordinator.boot();
    await until(() => second.coordinator.chatReady);
    expect(second.port.activeModelId).toBe(modelId);
    // No second celebration.
    expect(second.ready).not.toHaveBeenCalled();
    expect(kind(second)).toBe('hidden');
  });
});

describe('managing models', () => {
  const rigs: Rig[] = [];
  const ready = async (options?: Parameters<typeof rig>[0]) => {
    const r = rig(options);
    rigs.push(r);
    await r.coordinator.boot();
    r.coordinator.getStarted();
    await until(() => r.coordinator.chatReady);
    r.coordinator.endCelebration();
    return r;
  };

  beforeEach(() => AsyncStorage.clear());
  afterEach(() => {
    rigs.splice(0).forEach(made => made.coordinator.dispose());
  });

  it('deletes the only model and adds it again', async () => {
    const r = await ready();
    const modelId = r.port.activeModelId!;
    await r.coordinator.remove(modelId);
    expect(r.port.activeModelId).toBeNull();
    expect(r.port.stateOf(modelId).status).toBe('not_installed');
    expect(await r.backend.usedBytes()).toBe(0);
    expect(kind(r)).toBe('missing');
    expect(r.coordinator.chatReady).toBe(false);
    // Nothing comes back by itself.
    await new Promise(resolve => setTimeout(resolve, 40));
    expect(kind(r)).toBe('missing');

    r.coordinator.resume();
    await until(() => r.coordinator.chatReady);
    expect(r.port.activeModelId).toBe(modelId);
    expect(kind(r)).toBe('hidden');
  });

  it('does not download a deleted model again after a restart', async () => {
    const storage = new MemoryStorage();
    const first = await ready({storage});
    await first.coordinator.remove(first.port.activeModelId!);
    first.coordinator.dispose();

    const second = rig({storage});
    rigs.push(second);
    await second.coordinator.boot();
    await new Promise(resolve => setTimeout(resolve, 40));
    expect(kind(second)).toBe('missing');
    expect(await second.backend.usedBytes()).toBe(0);
  });

  it('switches to another installed model and back to automatic', async () => {
    const r = await ready({device: 'large'});
    const smart = r.port.activeModelId!;
    const other = r.port.models.find(
      model => model.supported && !model.unrestricted && model.id !== smart,
    )!;
    r.coordinator.download(other.id);
    await until(() => r.port.stateOf(other.id).status === 'ready');
    // A download by hand does not change the model in use.
    expect(r.port.activeModelId).toBe(smart);

    r.coordinator.choose(other.id);
    await until(
      () =>
        r.port.activeModelId === other.id &&
        r.port.stateOf(other.id).status === 'loaded',
    );
    expect(r.coordinator.prefs.automatic).toBe(false);

    r.coordinator.choose('auto');
    await until(
      () =>
        r.port.activeModelId === smart &&
        r.port.stateOf(smart).status === 'loaded',
    );
  });

  it('keeps chatting on another model when the one in use is deleted', async () => {
    const r = await ready({device: 'large'});
    const smart = r.port.activeModelId!;
    const other = r.port.models.find(
      model => model.supported && !model.unrestricted && model.id !== smart,
    )!;
    r.coordinator.download(other.id);
    await until(() => r.port.stateOf(other.id).status === 'ready');
    await r.coordinator.remove(smart);
    await until(() => r.coordinator.chatReady);
    expect(r.port.activeModelId).toBe(other.id);
    expect(r.coordinator.prefs.selection).toBe(other.id);
  });

  it('downloads and then switches when a model that is not installed is chosen', async () => {
    const r = await ready({device: 'large'});
    const smart = r.port.activeModelId!;
    await r.coordinator.remove(smart);
    r.coordinator.choose('auto');
    await until(() => r.coordinator.chatReady);
    expect(r.port.activeModelId).toBe(smart);
  });
});
