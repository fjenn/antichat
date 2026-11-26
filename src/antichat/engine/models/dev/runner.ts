/**
 * The first-run path, end to end and unattended:
 * classify -> select -> download -> verify -> load -> generate a sentence.
 * Every step is written to the dev log so the host script can check it.
 */
import {reaction} from 'mobx';

import {connectivity} from '../../../adapters/connectivity';
import {createModelRuntime, ModelRuntime} from '../../../adapters/model';
import {modelStore} from '../../../../store';
import {antichatNative} from '../../downloads/native';
import {bundledCatalog} from '../catalog/bundledCatalog';
import {parseCatalog} from '../catalog/parse';
import {ed25519Verifier} from '../catalog/signature';
import {CatalogStore} from '../catalog/store';
import type {Catalog} from '../catalog/types';
import type {DeviceSnapshot} from '../device/types';

import {MemoryStorage} from '../storage';

import type {ModelDevConfig} from './config';
import type {DevLog} from './devLog';

const GB = 1024 ** 3;
const RETRY_AFTER_MS = 8000;
const sleep = (ms: number) =>
  new Promise<void>(resolve => setTimeout(resolve, ms));

async function fetchOverride(
  url: string,
  log: DevLog,
): Promise<Catalog | undefined> {
  try {
    const response = await fetch(url);
    const catalog = parseCatalog(await response.json());
    log.event('catalog_override', {url, serial: catalog.serial});
    return catalog;
  } catch (error) {
    log.event('catalog_override_failed', {url, error: String(error)});
    return undefined;
  }
}

export async function createDevRuntime(
  config: ModelDevConfig,
  log: DevLog,
): Promise<ModelRuntime> {
  const bundled = config.catalogOverrideUrl
    ? await fetchOverride(config.catalogOverrideUrl, log)
    : undefined;
  const mapDevice = config.device
    ? (snapshot: DeviceSnapshot): DeviceSnapshot => ({
        ...snapshot,
        totalRamBytes: config.device?.totalRamGb
          ? config.device.totalRamGb * GB
          : snapshot.totalRamBytes,
        availableBytes: config.device?.availableGb
          ? config.device.availableGb * GB
          : snapshot.availableBytes,
      })
    : undefined;
  const failInit = new Set(config.failInit ?? []);
  const hangInit = new Set(config.hangInit ?? []);
  const runtime = createModelRuntime({
    filesBaseUrl: config.filesBaseUrl,
    bundled,
    catalogUrl: config.catalogUrl,
    catalogPublicKeys: config.catalogKey ? [config.catalogKey] : undefined,
    mapDevice,
    askForNotifications: true,
    onReadyNotice: (modelId, shown) =>
      log.event('ready_notice', {modelId, shown}),
    beforeInit: request => {
      log.event('init_attempt', {
        modelId: request.model.id,
        kind: request.attempt.kind,
        backend: request.attempt.backend,
        gpuLayers: request.attempt.gpuLayers,
        contextSize: request.attempt.contextSize,
        vision: request.attempt.vision,
        injectedFailure: failInit.has(request.model.id),
      });
      if (hangInit.has(request.model.id)) {
        // Injected: a load that never returns, to be killed from outside. It
        // stands in for a load during which the OS kills the app.
        log.event('init_hang', {modelId: request.model.id});
        return new Promise<void>(() => undefined);
      }
      if (failInit.has(request.model.id)) {
        // Injected: stands in for an allocation failure on a phone.
        throw new Error(
          'failed to allocate: out of memory (injected by dev config)',
        );
      }
    },
  });

  const {engine} = runtime;
  // Connectivity flips, with the time the platform event arrived and the time
  // the flag changed, for the "within 2 s" check.
  reaction(
    () => [connectivity.online, connectivity.metered, connectivity.kind],
    ([online, metered, kind]) =>
      log.event('connectivity', {online, metered, kind}),
    {fireImmediately: true},
  );

  const last = new Map<string, string>();
  let lastProgressLog = 0;
  engine.subscribe(() => {
    for (const view of engine.models) {
      const state = view.state;
      const key =
        state.status === 'downloading'
          ? `downloading:${state.paused}:${state.pauseReason ?? ''}`
          : state.status === 'verifying'
            ? 'verifying'
            : JSON.stringify(state);
      if (last.get(view.id) !== key) {
        last.set(view.id, key);
        log.event('model_state', {modelId: view.id, state});
      } else if (
        state.status === 'downloading' &&
        Date.now() - lastProgressLog >= 1000
      ) {
        lastProgressLog = Date.now();
        log.event('download_progress', {
          modelId: view.id,
          received: state.progress.receivedBytes,
          total: state.progress.totalBytes,
          bytesPerSecond: Math.round(state.progress.bytesPerSecond ?? 0),
        });
      }
    }
    writeStatus(runtime, log, {});
  });
  reaction(
    () => engine.notices.map(n => n.id).join(','),
    () => log.event('notices', {notices: engine.notices}),
  );
  return runtime;
}

let extra: Record<string, unknown> = {};

export function writeStatus(
  runtime: ModelRuntime,
  log: DevLog,
  more: Record<string, unknown>,
): void {
  extra = {...extra, ...more};
  const {engine} = runtime;
  log.status({
    mode: 'firstRun',
    phase: engine.phase,
    deviceClass: engine.deviceClass,
    recommended: engine.recommendedModelId,
    unrestricted: engine.unrestrictedModelId,
    active: engine.activeModelId,
    online: connectivity.online,
    states: Object.fromEntries(
      engine.models
        .filter(m => m.state.status !== 'not_installed')
        .map(m => [m.id, m.state]),
    ),
    notices: engine.notices,
    ...extra,
  });
}

export async function generateSentence(
  runtime: ModelRuntime,
  log: DevLog,
  prompt: string,
  maxTokens: number,
): Promise<string> {
  const completion = modelStore.engine;
  if (!completion) {
    throw new Error('no model is loaded');
  }
  const started = Date.now();
  let firstTokenAt = 0;
  let tokens = 0;
  const result = await completion.completion(
    {
      messages: [{role: 'user', content: prompt}],
      n_predict: maxTokens,
      temperature: 0.7,
      jinja: true,
      enable_thinking: false,
    } as any,
    data => {
      if (data.token) {
        tokens += 1;
        firstTokenAt ||= Date.now();
      }
    },
  );
  const text = (result.content ?? result.text ?? '').trim();
  const seconds = (Date.now() - (firstTokenAt || started)) / 1000;
  log.event('generated', {
    text,
    tokens,
    ttftMs: firstTokenAt ? firstTokenAt - started : null,
    tokensPerSecond:
      seconds > 0 ? Math.round((tokens / seconds) * 10) / 10 : null,
    nativeTokensPerSecond: result.timings?.predicted_per_second,
  });
  return text;
}

/** classify -> select -> download -> verify -> load -> generate. */
export async function runFirstRun(
  runtime: ModelRuntime,
  config: ModelDevConfig,
  log: DevLog,
): Promise<void> {
  const {engine} = runtime;
  try {
    const memoryBefore = await antichatNative?.memoryInfo().catch(() => null);
    await runtime.start();
    const device = engine.device;
    log.event('classified', {
      deviceClass: engine.deviceClass,
      memoryClass: device?.memoryClass,
      chipClass: device?.chipClass,
      upstreamTier: device?.upstreamTier,
      totalRamBytes: device?.snapshot.totalRamBytes,
      availableBytes: device?.snapshot.availableBytes,
      budget: device?.budget,
      gpu: device?.gpu,
      machine: device?.snapshot.machine,
      isEmulator: device?.snapshot.isEmulator,
      memoryInfo: memoryBefore,
      recommended: engine.recommendedModelId,
      unrestricted: engine.unrestrictedModelId,
      capabilities: engine.capabilities,
    });
    if (config.catalogUrl) {
      // The runtime refreshes by itself at start; this reports where it ended.
      const refresh = await runtime.catalogStore.refresh();
      log.event('catalog_refresh', {
        result: refresh,
        serialInForce: runtime.catalogStore.catalog.serial,
      });
    }
    // Signature checks against a store of their own, so they change nothing.
    for (const url of config.catalogChecks ?? []) {
      const probe = new CatalogStore({
        bundled: bundledCatalog,
        storage: new MemoryStorage(),
        appVersion: '99.0.0',
        url,
        fetchText: async target => {
          const response = await fetch(target);
          return {status: response.status, text: await response.text()};
        },
        verifier: ed25519Verifier(config.catalogKey ? [config.catalogKey] : []),
      });
      log.event('catalog_check', {url, result: await probe.refresh()});
    }
    writeStatus(runtime, log, {});

    await engine.getStarted();
    // getStarted returns when the chain has settled: loaded, waiting for the
    // network, or failed. A fallback (smaller model) is part of the chain.
    log.event('first_run_settled', {
      active: engine.activeModelId,
      states: engine.models
        .filter(m => m.state.status !== 'not_installed')
        .map(m => ({id: m.id, state: m.state})),
    });
    writeStatus(runtime, log, {settled: true});

    // Not loaded yet means a download that waits (offline) or failed. Wait for
    // it; a failure is retried the way a tap on "Retry" would.
    for (;;) {
      const active = engine.activeModelId;
      if (active && engine.stateOf(active).status === 'loaded') {
        break;
      }
      await sleep(1000);
      const failed = engine.models.find(
        m =>
          m.id === engine.recommendedModelId &&
          m.state.status === 'failed' &&
          m.state.retryable,
      );
      if (failed) {
        await sleep(RETRY_AFTER_MS);
        log.event('auto_retry', {modelId: failed.id, state: failed.state});
        // Not awaited: the loop keeps watching while the retry runs.
        engine.retry(failed.id).catch(() => undefined);
        await sleep(2000);
      }
    }

    const active = engine.activeModelId as string;
    const text = await generateSentence(
      runtime,
      log,
      config.prompt ??
        'Write a story of about 200 words about a lighthouse keeper.',
      config.maxTokens ?? 260,
    );
    // The speed calibration needs a few seconds of streaming to conclude.
    await sleep(500);
    const memoryAfter = await antichatNative?.memoryInfo().catch(() => null);
    writeStatus(runtime, log, {
      finished: true,
      ok: text.length > 0,
      text,
      loaded: engine.stateOf(active),
      memoryAfter,
    });
    log.event('first_run_finished', {
      ok: text.length > 0,
      active,
      state: engine.stateOf(active),
    });
  } catch (error) {
    log.event('first_run_error', {
      error: String(error),
      stack: String((error as Error)?.stack ?? '').slice(0, 1200),
    });
    writeStatus(runtime, log, {
      finished: true,
      ok: false,
      error: String(error),
    });
  }
}
