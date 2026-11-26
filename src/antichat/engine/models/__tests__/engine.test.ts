import {autorun} from 'mobx';

import raw from '../catalog/bundled.json';
import {bundledCatalog} from '../catalog/bundledCatalog';
import {getModel} from '../catalog/lookup';
import {CatalogStore} from '../catalog/store';
import type {CatalogModel} from '../catalog/types';
import type {DeviceSnapshot} from '../device/types';
import {ModelEngine} from '../engine';
import {LoadJournal} from '../policy/initChain';
import type {ModelNotice} from '../port';
import {MemoryStorage} from '../storage';

import {android, GB, ios, MB} from './fixtures/devices';
import {FakeBackend, FakeContext, flush} from './fixtures/fakeBackend';

const E2B = 'gemma-4-e2b-qat';
const E4B = 'gemma-4-e4b-qat';
const LFM = 'lfm3-1.7b';
const model = (id: string) => getModel(bundledCatalog, id) as CatalogModel;
const e2bFiles = [model(E2B).files[0], model(E2B).projector!];

const phoneC = () => ios(7.5, 3.0, 'iPhone17,1');
const phoneD = () => ios(11.45, 3.17, 'iPhone18,1');

async function start(
  snapshot: DeviceSnapshot = phoneC(),
  setup: (
    backend: FakeBackend,
    storage: MemoryStorage,
  ) => void | Promise<void> = () => undefined,
) {
  const backend = new FakeBackend(snapshot);
  const storage = new MemoryStorage();
  await setup(backend, storage);
  let clock = 1_000_000;
  const time = {
    advance: (ms: number) => {
      clock += ms;
    },
  };
  const engine = new ModelEngine<FakeContext>({
    backend,
    storage,
    now: () => clock,
  });
  await engine.initialize();
  const statuses: string[] = [];
  const watched = engine.recommendedModelId as string;
  engine.subscribe(() => {
    const status = engine.stateOf(watched).status;
    if (statuses[statuses.length - 1] !== status) {
      statuses.push(status);
    }
  });
  return {engine, backend, storage, statuses, time};
}

const noticeOf = <K extends ModelNotice['kind']>(
  engine: ModelEngine<FakeContext>,
  kind: K,
) =>
  engine.notices.find(n => n.kind === kind) as Extract<ModelNotice, {kind: K}>;

/** Stream tokens at a rate through the engine's clock. */
function generate(
  engine: ModelEngine<FakeContext>,
  time: {advance: (ms: number) => void},
  tokensPerSecond: number,
  seconds: number,
) {
  engine.noteGeneratedTokens(1);
  const step = 1000 / tokensPerSecond;
  for (let t = step; t <= seconds * 1000 + 0.001; t += step) {
    time.advance(step);
    engine.noteGeneratedTokens(1);
  }
}

describe('start-up', () => {
  it('detects the phone and recommends its model', async () => {
    const {engine} = await start();
    expect(engine.phase).toBe('ready');
    expect(engine.deviceClass).toBe('C');
    expect(engine.recommendedModelId).toBe(E2B);
    expect(engine.unrestrictedModelId).toBe('qwen3.5-4b-unrestricted');
    expect(engine.activeModelId).toBeNull();
    expect(engine.stateOf(E2B)).toEqual({status: 'not_installed'});
    expect(engine.capabilities).toMatchObject({
      modelId: E2B,
      vision: {available: true},
    });
  });

  it('lists models: recommended first, add-ons last, with what fits', async () => {
    const {engine} = await start();
    const views = engine.models;
    expect(views[0]).toMatchObject({
      id: E2B,
      recommended: true,
      supported: true,
      vision: true,
      downloadBytes: 2620370976 + 985654080,
      openSource: true,
    });
    const firstAddOn = views.findIndex(v => v.unrestricted);
    expect(views.slice(firstAddOn).every(v => v.unrestricted)).toBe(true);
    // The 9B cannot run on an 8 GB iPhone; it is listed as unsupported.
    expect(views.find(v => v.id === 'qwen3.5-9b')).toMatchObject({
      supported: false,
      downloadBytes: 5680522464,
    });
    expect(views.find(v => v.id === LFM)).toMatchObject({
      openSource: false,
      licenceName: 'LFM Open License v1.0',
    });
  });

  it('is empty before initialize, and commands need it', async () => {
    const engine = new ModelEngine({backend: new FakeBackend(phoneC())});
    expect(engine.phase).toBe('idle');
    expect(engine.models).toEqual([]);
    expect(engine.capabilities).toBeNull();
    expect(engine.deviceClass).toBeNull();
    expect(engine.recommendedModelId).toBeNull();
    expect(engine.unrestrictedModelId).toBeNull();
    await expect(engine.getStarted()).rejects.toThrow(/initialize/);
    await expect(engine.download(E2B)).resolves.toBeUndefined();
  });

  it('finds models that are already installed', async () => {
    const {engine} = await start(phoneC(), backend =>
      backend.install(e2bFiles),
    );
    expect(engine.stateOf(E2B)).toEqual({status: 'ready'});
    // Weights alone are not enough when the projector is part of the choice.
    const partial = await start(phoneC(), backend =>
      backend.install([e2bFiles[0]]),
    );
    expect(partial.engine.stateOf(E2B).status).toBe('not_installed');
  });

  it('uses the catalogue store and hides revoked models', async () => {
    const backend = new FakeBackend(phoneC());
    const storage = new MemoryStorage();
    await storage.setItem(
      'antichat.catalog.lastGood',
      JSON.stringify({...raw, serial: raw.serial + 1, revoked: [E2B]}),
    );
    const catalogStore = new CatalogStore({
      bundled: bundledCatalog,
      storage,
      appVersion: '1.0.0',
    });
    const engine = new ModelEngine({backend, storage, catalogStore});
    await engine.initialize();
    expect(engine.recommendedModelId).toBe(LFM);
    expect(engine.models.some(v => v.id === E2B)).toBe(false);
    await engine.download(E2B);
    expect(engine.stateOf(E2B).status).toBe('not_installed');
  });
});

describe('first run', () => {
  it('downloads, verifies and loads with one call', async () => {
    const {engine, backend, statuses} = await start();
    await engine.getStarted();
    expect(statuses).toEqual([
      'not_installed',
      'downloading',
      'verifying',
      'ready',
      'loading',
      'loaded',
    ]);
    expect(backend.log).toEqual([
      'download gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf',
      'download mmproj-F16.gguf',
      'verify gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf',
      'verify mmproj-F16.gguf',
      `init ${E2B} gpu`,
    ]);
    expect(engine.activeModelId).toBe(E2B);
    expect(engine.stateOf(E2B)).toEqual({
      status: 'loaded',
      info: {
        backend: 'metal',
        gpuLayers: 99,
        contextSize: 8192,
        vision: true,
        attempt: 'gpu',
        degraded: false,
        tokensPerSecond: undefined,
      },
    });
    expect(backend.loadRequests[0].projector?.path).toBe('mmproj-F16.gguf');
    expect(engine.notices).toEqual([]);
  });

  it('waits for the app to be in front before it loads', async () => {
    const {engine, backend} = await start();
    let comeBack: () => void = () => undefined;
    (backend as any).waitUntilForeground = () =>
      new Promise<void>(resolve => {
        comeBack = resolve;
      });
    const running = engine.getStarted();
    await flush();
    await flush();
    // Downloaded and verified in the background: installed, not loaded.
    expect(engine.stateOf(E2B).status).toBe('ready');
    expect(backend.loadRequests).toHaveLength(0);
    comeBack();
    await running;
    expect(engine.stateOf(E2B).status).toBe('loaded');
  });

  it('goes straight to loading when the model is already there', async () => {
    const {engine, backend} = await start(phoneC(), b => b.install(e2bFiles));
    await engine.getStarted();
    expect(backend.log).toEqual([`init ${E2B} gpu`]);
    expect(engine.stateOf(E2B).status).toBe('loaded');
  });

  it('asks before using cellular data, then continues to a loaded model', async () => {
    const {engine, backend} = await start(phoneC(), b => {
      b.networkStatus = {online: true, metered: true};
    });
    await engine.getStarted();
    expect(engine.stateOf(E2B).status).toBe('not_installed');
    const notice = noticeOf(engine, 'confirm_metered');
    expect(notice).toMatchObject({
      modelId: E2B,
      bytes: 2620370976 + 985654080,
      needsAnswer: true,
    });
    expect(backend.log).toEqual([]);

    await engine.answerNotice(notice.id, true);
    expect(engine.notices).toEqual([]);
    expect(engine.stateOf(E2B).status).toBe('loaded');
  });

  it('does nothing when cellular is declined', async () => {
    const {engine, backend} = await start(phoneC(), b => {
      b.networkStatus = {online: true, metered: true};
    });
    await engine.getStarted();
    await engine.answerNotice(noticeOf(engine, 'confirm_metered').id, false);
    expect(engine.notices).toEqual([]);
    expect(backend.log).toEqual([]);
    expect(engine.stateOf(E2B).status).toBe('not_installed');
    await engine.answerNotice('unknown-notice', true);
  });

  it('shows offline as a retryable state, and retries', async () => {
    const {engine, backend} = await start(phoneC(), b => {
      b.networkStatus = {online: false, metered: false};
    });
    await engine.getStarted();
    expect(engine.stateOf(E2B)).toMatchObject({
      status: 'failed',
      reason: 'offline',
      retryable: true,
    });
    backend.networkStatus = {online: true, metered: false};
    await engine.retry(E2B);
    // First run asked for a loaded model, so the retry goes all the way.
    expect(engine.stateOf(E2B).status).toBe('loaded');
  });

  it('picks a smaller model when the disk is nearly full, and says so', async () => {
    const {engine, backend} = await start(phoneC(), b => {
      b.freeBytes = 2 * GB;
    });
    await engine.getStarted();
    expect(engine.recommendedModelId).toBe(LFM);
    expect(engine.stateOf(LFM).status).toBe('loaded');
    expect(noticeOf(engine, 'storage_limited')).toMatchObject({
      wantedModelId: E2B,
      freeBytes: 2 * GB,
      needsAnswer: false,
    });
    expect(backend.log[0]).toBe('download LFM3-1.7B-Q4_K_M.gguf');
  });

  it('reports a full disk as a state', async () => {
    const {engine} = await start(phoneC(), b => {
      b.freeBytes = 10 * MB;
    });
    await engine.getStarted();
    expect(engine.stateOf(E2B)).toMatchObject({
      status: 'failed',
      reason: 'storage_full',
      retryable: false,
    });
  });
});

describe('downloads', () => {
  const manual = (b: FakeBackend) => {
    b.manualDownloads = true;
  };

  it('reports combined progress over both files', async () => {
    const {engine, backend} = await start(phoneC(), manual);
    const running = engine.download(E2B);
    await flush();
    const [weights, projector] = e2bFiles;
    backend.progress(weights, 1_000_000_000, 5_000_000);
    expect(engine.stateOf(E2B)).toMatchObject({
      status: 'downloading',
      paused: false,
      progress: {
        receivedBytes: 1_000_000_000,
        totalBytes: weights.sizeBytes + projector.sizeBytes,
        bytesPerSecond: 5_000_000,
      },
    });
    backend.complete(weights);
    await flush();
    backend.progress(projector, 100);
    expect((engine.stateOf(E2B) as any).progress.receivedBytes).toBe(
      weights.sizeBytes + 100,
    );
    backend.complete(projector);
    await running;
    expect(engine.stateOf(E2B)).toEqual({status: 'ready'});
    // download() alone does not load.
    expect(engine.activeModelId).toBeNull();
  });

  it('pauses and resumes on request', async () => {
    const {engine, backend} = await start(phoneC(), manual);
    const running = engine.download(E2B);
    await flush();
    engine.pause(E2B);
    expect(engine.stateOf(E2B)).toMatchObject({
      paused: true,
      pauseReason: 'user',
    });
    engine.pause(E2B);
    await engine.resume(E2B);
    expect(engine.stateOf(E2B)).toMatchObject({paused: false});
    await engine.resume(E2B);
    // Both files download together, so both are paused and resumed.
    expect(backend.log.filter(l => /^(pause|resume)/.test(l))).toEqual([
      'pause gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf',
      'pause mmproj-F16.gguf',
      'resume gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf',
      'resume mmproj-F16.gguf',
    ]);
    backend.complete(e2bFiles[0]);
    await flush();
    backend.complete(e2bFiles[1]);
    await running;
    expect(engine.stateOf(E2B).status).toBe('ready');
  });

  it('cancels and deletes the partial files', async () => {
    const {engine, backend} = await start(phoneC(), manual);
    const running = engine.download(E2B);
    await flush();
    backend.progress(e2bFiles[0], 5000);
    await engine.cancel(E2B);
    await running;
    expect(engine.stateOf(E2B)).toEqual({status: 'not_installed'});
    expect(backend.disk.size).toBe(0);
    expect(backend.log).toContain('remove gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf');
    // remove() on a download is a cancel.
    const again = engine.download(E2B);
    await flush();
    await engine.remove(E2B);
    await again;
    expect(engine.stateOf(E2B).status).toBe('not_installed');
  });

  it('ignores a second download of the same model', async () => {
    const {engine, backend} = await start(phoneC(), manual);
    const running = engine.download(E2B);
    await flush();
    await engine.download(E2B);
    // One live download per file (weights and projector), not two per file.
    expect(backend.live).toHaveLength(2);
    await engine.cancel(E2B);
    await running;
  });

  it('waits when the connection drops, and continues when it returns', async () => {
    const {engine, backend} = await start(phoneC(), manual);
    const running = engine.download(E2B);
    await flush();
    const [weights, projector] = e2bFiles;
    backend.progress(weights, 1_000_000_000);
    backend.networkStatus = {online: false, metered: false};
    backend.fail(weights, new Error('connection lost'));
    await running;
    expect(engine.stateOf(E2B)).toMatchObject({
      status: 'downloading',
      paused: true,
      pauseReason: 'offline',
    });

    // Still offline: nothing happens, also when the user taps resume.
    await engine.onNetworkChange();
    await engine.resume(E2B);
    expect(backend.live).toHaveLength(0);
    expect(engine.stateOf(E2B)).toMatchObject({pauseReason: 'offline'});

    backend.networkStatus = {online: true, metered: false};
    const resumed = engine.onNetworkChange();
    await flush();
    // Continues from the bytes already on disk.
    expect(engine.stateOf(E2B)).toMatchObject({
      paused: false,
      progress: {receivedBytes: 1_000_000_000},
    });
    backend.complete(weights);
    await flush();
    backend.complete(projector);
    await resumed;
    expect(engine.stateOf(E2B).status).toBe('ready');
  });

  it('shows a running download as waiting when the phone goes offline', async () => {
    const {engine, backend} = await start(phoneC(), manual);
    const running = engine.download(E2B);
    await flush();
    backend.progress(e2bFiles[0], 1_000_000_000);
    // The native download has not failed: it would keep retrying by itself.
    backend.networkStatus = {online: false, metered: false};
    await engine.onNetworkChange();
    expect(engine.stateOf(E2B)).toMatchObject({
      status: 'downloading',
      paused: true,
      pauseReason: 'offline',
    });
    expect(backend.log.filter(l => l.startsWith('pause'))).toHaveLength(2);

    backend.networkStatus = {online: true, metered: false};
    await engine.onNetworkChange();
    expect(engine.stateOf(E2B)).toMatchObject({paused: false});
    expect(backend.log.filter(l => l.startsWith('resume'))).toHaveLength(2);
    backend.complete(e2bFiles[0]);
    backend.complete(e2bFiles[1]);
    await running;
    expect(engine.stateOf(E2B).status).toBe('ready');
  });

  it('stops spending data when Wi-Fi turns into cellular', async () => {
    const {engine, backend} = await start(phoneC(), manual);
    const running = engine.download(E2B);
    await flush();
    backend.networkStatus = {online: true, metered: true};
    await engine.onNetworkChange();
    expect(engine.stateOf(E2B)).toMatchObject({
      paused: true,
      pauseReason: 'metered',
    });
    expect(backend.current().paused).toBe(true);
    // Still cellular: stays paused.
    await engine.onNetworkChange();
    expect(backend.current().paused).toBe(true);

    backend.networkStatus = {online: true, metered: false};
    await engine.onNetworkChange();
    expect(engine.stateOf(E2B)).toMatchObject({paused: false});
    expect(backend.current().paused).toBe(false);
    await engine.cancel(E2B);
    await running;
  });

  it('keeps going on cellular when the user allowed it', async () => {
    const {engine} = await start(phoneC(), b => {
      b.manualDownloads = true;
      b.networkStatus = {online: true, metered: true};
    });
    const running = engine.download(E2B, {allowMetered: true});
    await flush();
    await engine.onNetworkChange();
    expect(engine.stateOf(E2B)).toMatchObject({paused: false});
    engine.pause(E2B);
    // A pause the user asked for is not undone by the network.
    await engine.onNetworkChange();
    expect(engine.stateOf(E2B)).toMatchObject({paused: true});
    await engine.cancel(E2B);
    await running;
  });

  it('rejects a corrupt file, deletes it, and a retry fetches it again', async () => {
    const {engine, backend} = await start();
    const projector = e2bFiles[1];
    backend.corrupt.add(projector.sha256);
    await engine.download(E2B);
    expect(engine.stateOf(E2B)).toMatchObject({
      status: 'failed',
      reason: 'checksum_mismatch',
      stage: 'verify',
      detail: 'mmproj-F16.gguf does not match its checksum',
    });
    expect(backend.disk.has(projector.sha256)).toBe(false);
    expect(backend.disk.has(e2bFiles[0].sha256)).toBe(true);

    backend.corrupt.clear();
    backend.log.length = 0;
    await engine.retry(E2B);
    // Only the bad file is downloaded again.
    expect(backend.log.filter(l => l.startsWith('download'))).toEqual([
      'download mmproj-F16.gguf',
    ]);
    expect(engine.stateOf(E2B).status).toBe('ready');
  });

  it('loads after the retry when the first run hit a corrupt file', async () => {
    const {engine, backend} = await start();
    backend.corrupt.add(e2bFiles[0].sha256);
    await engine.getStarted();
    expect(engine.stateOf(E2B)).toMatchObject({
      status: 'failed',
      reason: 'checksum_mismatch',
    });
    backend.corrupt.clear();
    // "Get started" meant a loaded model; the retry finishes that.
    await engine.retry(E2B);
    expect(engine.stateOf(E2B).status).toBe('loaded');
    expect(engine.activeModelId).toBe(E2B);
  });

  it('treats a verifier that throws as a failed check', async () => {
    const {engine, backend} = await start();
    backend.verify = async () => {
      throw new Error('read error');
    };
    await engine.download(E2B);
    expect(engine.stateOf(E2B)).toMatchObject({
      reason: 'checksum_mismatch',
      detail: 'read error',
    });
  });

  it('reports a server error as a failed download', async () => {
    const {engine, backend} = await start(phoneC(), b => {
      b.downloadError = new Error('HTTP 503');
    });
    expect(backend.live).toHaveLength(0);
    await engine.download(E2B);
    expect(engine.stateOf(E2B)).toMatchObject({
      status: 'failed',
      reason: 'download_failed',
      detail: 'HTTP 503',
      retryable: true,
    });
    backend.downloadError = null;
    await engine.retry(E2B);
    expect(engine.stateOf(E2B).status).toBe('ready');
    // retry on a healthy model is a no-op
    await engine.retry(E2B);
  });

  it('removes an installed model, unloading it first', async () => {
    const {engine, backend} = await start();
    await engine.getStarted();
    await engine.remove(E2B);
    expect(backend.released).toHaveLength(1);
    expect(engine.stateOf(E2B)).toEqual({status: 'not_installed'});
    expect(engine.activeModelId).toBeNull();
    expect(backend.disk.size).toBe(0);
    await engine.remove('ghost');
  });
});

describe('loading and the fallback chain', () => {
  const installed = (b: FakeBackend) => b.install(e2bFiles);

  it('falls back to the CPU when the GPU fails, and marks the load degraded', async () => {
    const {engine, backend} = await start(phoneC(), b => {
      installed(b);
      b.onInit = request => {
        if (request.attempt.backend !== 'cpu') {
          throw new Error('Metal init failed');
        }
      };
    });
    await engine.load(E2B);
    expect(backend.log).toEqual([
      `init ${E2B} gpu`,
      `init ${E2B} gpu_reduced`,
      `init ${E2B} cpu`,
    ]);
    expect(engine.stateOf(E2B)).toMatchObject({
      status: 'loaded',
      info: {backend: 'cpu', gpuLayers: 0, attempt: 'cpu', degraded: true},
    });
  });

  it('uses a fresh memory reading for the reduced attempt', async () => {
    const {engine, backend} = await start(phoneC(), b => {
      installed(b);
      // Less than the Metal reserve is free: no reduced attempt is planned.
      b.availableBytes = 1 * GB;
      b.onInit = request => {
        if (request.attempt.backend !== 'cpu') {
          throw new Error('Metal init failed');
        }
      };
    });
    await engine.load(E2B);
    expect(backend.log).toEqual([`init ${E2B} gpu`, `init ${E2B} cpu`]);
  });

  it('falls back to the smaller model when nothing loads, without crashing', async () => {
    const {engine, backend} = await start(phoneC(), b => {
      installed(b);
      b.onInit = request => {
        if (request.model.id === E2B) {
          throw new Error('failed to allocate buffer: out of memory');
        }
      };
    });
    await engine.load(E2B);
    expect(engine.stateOf(E2B)).toMatchObject({
      status: 'failed',
      reason: 'out_of_memory',
      stage: 'load',
    });
    // The phone moved to LFM3: downloaded, verified, loaded.
    expect(engine.recommendedModelId).toBe(LFM);
    expect(engine.activeModelId).toBe(LFM);
    expect(engine.stateOf(LFM).status).toBe('loaded');
    expect(noticeOf(engine, 'load_fell_back')).toMatchObject({
      from: E2B,
      to: LFM,
    });
    expect(backend.log.filter(l => l.startsWith('init'))).toHaveLength(5);
    expect(engine.capabilities?.modelId).toBe(LFM);
  });

  it('remembers the demotion on the next launch', async () => {
    const first = await start(phoneC(), b => {
      installed(b);
      b.onInit = request => {
        if (request.model.id === E2B) {
          throw new Error('unsupported architecture');
        }
      };
    });
    await first.engine.load(E2B);
    expect(first.engine.stateOf(E2B)).toMatchObject({reason: 'load_failed'});
    await flush();

    const engine = new ModelEngine({
      backend: new FakeBackend(phoneC()),
      storage: first.storage,
    });
    await engine.initialize();
    expect(engine.recommendedModelId).toBe(LFM);
  });

  it('does not swap a model the user picked by hand', async () => {
    const qwen = model('qwen3.5-4b');
    const {engine} = await start(phoneC(), b => {
      b.install([qwen.files[0], qwen.projector!]);
      b.onInit = () => {
        throw new Error('nope');
      };
    });
    await engine.load('qwen3.5-4b');
    expect(engine.stateOf('qwen3.5-4b')).toMatchObject({
      status: 'failed',
      reason: 'load_failed',
    });
    expect(engine.recommendedModelId).toBe(E2B);
    expect(engine.notices).toEqual([]);
    expect(engine.activeModelId).toBeNull();
  });

  it('only loads a model that is ready', async () => {
    const {engine, backend} = await start();
    await engine.load(E2B);
    await engine.load('ghost');
    expect(backend.loadRequests).toEqual([]);
  });

  it('unloads the current model before loading another', async () => {
    const lfm = model(LFM);
    const {engine, backend} = await start(phoneC(), b => {
      installed(b);
      b.install([lfm.files[0]]);
    });
    await engine.load(E2B);
    await engine.load(LFM);
    expect(backend.log).toEqual([
      `init ${E2B} gpu`,
      `release ${E2B}`,
      `init ${LFM} gpu`,
    ]);
    expect(engine.stateOf(E2B).status).toBe('ready');
    expect(engine.activeModelId).toBe(LFM);
    await engine.unload();
    expect(engine.activeModelId).toBeNull();
    await engine.unload();
  });

  it('retries a failed load from "ready"', async () => {
    let fail = true;
    const qwen = model('qwen3.5-4b');
    const {engine} = await start(phoneC(), b => {
      b.install([qwen.files[0], qwen.projector!]);
      b.onInit = () => {
        if (fail) {
          throw new Error('nope');
        }
      };
    });
    await engine.load('qwen3.5-4b');
    fail = false;
    await engine.retry('qwen3.5-4b');
    expect(engine.stateOf('qwen3.5-4b').status).toBe('loaded');
  });

  it('skips the attempt that killed the app last time', async () => {
    const {engine, backend} = await start(phoneC(), async (b, storage) => {
      installed(b);
      await new LoadJournal(storage).begin(E2B, 'gpu');
    });
    expect(engine.recommendedModelId).toBe(E2B);
    await engine.load(E2B);
    expect(backend.log).toEqual([`init ${E2B} gpu_reduced`]);
    expect(engine.stateOf(E2B)).toMatchObject({
      info: {attempt: 'gpu_reduced', degraded: false},
    });
  });

  it('gives up on a model whose CPU load killed the app', async () => {
    const {engine} = await start(phoneC(), async (_b, storage) => {
      await new LoadJournal(storage).begin(E2B, 'cpu');
    });
    expect(engine.recommendedModelId).toBe(LFM);
  });
});

describe('calibration', () => {
  it('records the speed and says nothing when the phone is fast enough', async () => {
    const {engine, time} = await start();
    await engine.getStarted();
    generate(engine, time, 30, 5);
    expect(engine.stateOf(E2B)).toMatchObject({
      status: 'loaded',
      info: {tokensPerSecond: expect.closeTo(30, 0)},
    });
    expect(engine.notices).toEqual([]);
  });

  it('offers the smaller model once when the phone is too slow', async () => {
    const {engine, time, storage, backend} = await start(phoneD());
    await engine.getStarted();
    expect(engine.activeModelId).toBe(E4B);
    generate(engine, time, 4, 5);
    const notice = noticeOf(engine, 'slow_offer_smaller');
    expect(notice).toMatchObject({
      modelId: E4B,
      offerModelId: E2B,
      needsAnswer: true,
    });
    expect(notice.tokensPerSecond).toBeCloseTo(4, 0);

    // Declined: stays on the model, and is not asked again on later loads.
    await engine.answerNotice(notice.id, false);
    expect(engine.activeModelId).toBe(E4B);
    await engine.unload();
    await engine.load(E4B);
    generate(engine, time, 4, 5);
    expect(engine.notices).toEqual([]);
    expect(engine.stateOf(E4B)).toMatchObject({
      info: {tokensPerSecond: expect.closeTo(4, 0)},
    });
    await flush();

    // And not after a restart either.
    const again = new ModelEngine<FakeContext>({backend, storage});
    await again.initialize();
    await again.load(E4B);
    expect(again.stateOf(E4B)).toMatchObject({
      info: {tokensPerSecond: expect.closeTo(4, 0)},
    });
    expect(again.recommendedModelId).toBe(E4B);
  });

  it('switches to the smaller model when the offer is accepted', async () => {
    const {engine, time} = await start(phoneD());
    await engine.getStarted();
    generate(engine, time, 4, 5);
    await engine.answerNotice(noticeOf(engine, 'slow_offer_smaller').id, true);
    expect(engine.recommendedModelId).toBe(E2B);
    expect(engine.activeModelId).toBe(E2B);
    expect(engine.stateOf(E2B).status).toBe('loaded');
    expect(engine.stateOf(E4B).status).toBe('ready');
  });

  it('does not mistake reading time for a slow phone', async () => {
    const {engine, time} = await start();
    await engine.getStarted();
    generate(engine, time, 30, 3);
    await engine.noteGenerationFinished();
    time.advance(120_000);
    generate(engine, time, 30, 3);
    expect(engine.notices).toEqual([]);
    expect(engine.stateOf(E2B)).toMatchObject({
      info: {tokensPerSecond: expect.closeTo(30, 0)},
    });
  });

  it('starts one download when tapped twice', async () => {
    const {engine, backend} = await start();
    await Promise.all([engine.download(E2B), engine.download(E2B)]);
    expect(backend.log.filter(l => l.startsWith('download'))).toHaveLength(2);
    expect(engine.stateOf(E2B).status).toBe('ready');
  });

  it('draws no conclusion from a short answer', async () => {
    const {engine, time} = await start();
    await engine.getStarted();
    engine.noteGeneratedTokens(1);
    time.advance(6000);
    engine.noteGeneratedTokens(2);
    expect(engine.notices).toEqual([]);
    expect((engine.stateOf(E2B) as any).info.tokensPerSecond).toBeUndefined();
  });

  it('ignores tokens when nothing is loaded', async () => {
    const {engine} = await start();
    expect(() => engine.noteGeneratedTokens(5)).not.toThrow();
  });
});

describe('memory pressure', () => {
  it('frees helpers, then the projector, on a warning', async () => {
    const {engine, backend} = await start();
    await engine.getStarted();
    backend.log.length = 0;
    await engine.onMemoryPressure('warning', {
      generating: false,
      aux: ['embeddings'],
    });
    await engine.onMemoryPressure('warning', {generating: false, aux: []});
    expect(backend.log).toEqual([
      'release-aux embeddings',
      `release-projector ${E2B}`,
    ]);
    expect(engine.stateOf(E2B).status).toBe('loaded');
  });

  it('lets the answer finish before releasing the model', async () => {
    const {engine} = await start();
    await engine.getStarted();
    await engine.onMemoryPressure('critical', {generating: true, aux: []});
    expect(engine.stateOf(E2B).status).toBe('loaded');
    await engine.noteGenerationFinished();
    expect(engine.stateOf(E2B).status).toBe('ready');
    // Nothing more is pending.
    await engine.noteGenerationFinished();
  });

  it('switches to the smaller model after two forced releases', async () => {
    const {engine, time} = await start(phoneD());
    await engine.getStarted();
    await engine.onMemoryPressure('critical', {generating: false, aux: []});
    expect(engine.stateOf(E4B).status).toBe('ready');
    expect(engine.recommendedModelId).toBe(E4B);

    time.advance(60_000);
    await engine.load(E4B);
    await engine.onMemoryPressure('critical', {generating: false, aux: []});
    expect(engine.recommendedModelId).toBe(E2B);
    expect(noticeOf(engine, 'low_memory_switched')).toMatchObject({
      from: E4B,
      to: E2B,
      needsAnswer: false,
    });
  });

  it('copes with pressure when no model is loaded', async () => {
    const {engine, backend} = await start();
    await engine.onMemoryPressure('critical', {
      generating: false,
      aux: ['voice'],
    });
    expect(backend.log).toEqual(['release-aux voice']);
  });
});

describe('observation', () => {
  it('notifies plain subscribers and stops after unsubscribe', async () => {
    const {engine} = await start(phoneC(), b => b.install(e2bFiles));
    const listener = jest.fn();
    const unsubscribe = engine.subscribe(listener);
    await engine.load(E2B);
    const calls = listener.mock.calls.length;
    expect(calls).toBeGreaterThan(0);
    unsubscribe();
    await engine.unload();
    expect(listener).toHaveBeenCalledTimes(calls);
  });

  it('is observable through MobX', async () => {
    const {engine} = await start(phoneC(), b => b.install(e2bFiles));
    const seen: string[] = [];
    const stop = autorun(() => {
      const state = engine.models[0].state;
      seen.push(
        state.status === 'loading' && state.attempt
          ? `loading ${state.attempt.index + 1}/${state.attempt.total}`
          : state.status,
      );
    });
    await engine.load(E2B);
    stop();
    expect(seen).toEqual(['ready', 'loading', 'loading 1/4', 'loaded']);
  });

  it('dismisses notices', async () => {
    const {engine} = await start(phoneC(), b => {
      b.freeBytes = 2 * GB;
    });
    await engine.getStarted();
    const notice = noticeOf(engine, 'storage_limited');
    engine.dismissNotice(notice.id);
    expect(engine.notices).toEqual([]);
  });

  it('survives broken storage', async () => {
    const backend = new FakeBackend(phoneC());
    const broken = {
      getItem: async () => {
        throw new Error('disk');
      },
      setItem: async () => {
        throw new Error('disk');
      },
      removeItem: async () => {
        throw new Error('disk');
      },
    };
    const engine = new ModelEngine({backend, storage: broken});
    await engine.initialize();
    await engine.getStarted();
    expect(engine.stateOf(E2B).status).toBe('loaded');
  });

  it('runs on Android with the OpenCL weights', async () => {
    const {engine, backend} = await start(android(15, 6));
    await engine.getStarted();
    expect(engine.deviceClass).toBe('E');
    expect(backend.log[0]).toBe('download Qwen3.5-9B-Q4_0.gguf');
    expect(engine.stateOf('qwen3.5-9b')).toMatchObject({
      info: {backend: 'opencl', gpuLayers: 24},
    });
  });
});
