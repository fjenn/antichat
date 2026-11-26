/**
 * Model adapter (M5): the native half of the model engine.
 *
 * `PocketPalModelBackend` implements `ModelBackend` over
 *  - llama.rn (`initLlama`) and upstream's `modelStore`, which keeps owning the
 *    loaded context so upstream's chat pipeline works unchanged,
 *  - our resumable downloader (`engine/downloads`) and streamed SHA-256,
 *  - the device probe and the connectivity store.
 *
 * `createModelRuntime()` wires a `ModelEngine` to the phone: persistent
 * storage, the signed remote catalogue, connectivity changes, memory-pressure
 * events, token metering for the speed calibration and the "ready" notice.
 *
 * Nothing here shows an alert. `modelStore.initContext` is deliberately not
 * used: it asks the user with `Alert.alert` when memory looks short, and it
 * takes its parameters from settings; the engine decides those per attempt.
 */
import AsyncStorage from '@react-native-async-storage/async-storage';
import * as RNFS from '@dr.pogodin/react-native-fs';
import {getBackendDevicesInfo, initLlama, LlamaContext} from 'llama.rn';
import {runInAction} from 'mobx';
import {AppState, Platform} from 'react-native';

import {isDevBuild} from '../spike-ui/launch';
import DeviceInfo from 'react-native-device-info';

import {LocalCompletionEngine} from '../../api/completionEngines';
import NativeHardwareInfo from '../../specs/NativeHardwareInfo';
import {modelStore} from '../../store';
import {getLocalModelDefaultSettings} from '../../utils/chat';
import type {
  ApiCompletionParams,
  CompletionResult,
  CompletionStreamData,
} from '../../utils/completionTypes';
import {createContextInitParams} from '../../utils/contextInitParamsVersions';
import {Model, ModelOrigin} from '../../utils/types';

import {
  FileDownload,
  forgetNativeDownload,
  nativeBytesFor,
  sha256File,
  startFileDownload,
} from '../engine/downloads';
import {antichatNative, antichatNativeEvents} from '../engine/downloads/native';
import {bundledCatalog} from '../engine/models/catalog/bundledCatalog';
import {
  CATALOG_PUBLIC_KEYS,
  CATALOG_URL,
  MODEL_FILES_BASE_URL,
} from '../engine/models/catalog/remote';
import {ed25519Verifier} from '../engine/models/catalog/signature';
import {CatalogStore, FetchText} from '../engine/models/catalog/store';
import type {Catalog, CatalogFile} from '../engine/models/catalog/types';
import {readDeviceSnapshot} from '../engine/models/device/probe';
import type {DeviceSnapshot} from '../engine/models/device/types';
import {
  DownloadTask,
  LoadRequest,
  ModelBackend,
  ModelEngine,
} from '../engine/models/engine';
import type {NetworkStatus} from '../engine/models/policy/download';
import type {MemoryPressure} from '../engine/models/policy/lowMemory';

import {connectivity, startConnectivity} from './connectivity';
import {
  downloadNotice,
  notifyModelReady,
  requestNotificationPermission,
} from './notifications';

/** A loaded llama.rn context and the upstream model record that shows it. */
export interface LoadedContext {
  context: LlamaContext;
  modelId: string;
  storeModelId: string;
}

/** Values an expert set by hand; they win over the policy's choice at load. */
export interface ExpertOverrides {
  contextSize?: number;
  threads?: number;
  gpuLayers?: number;
  temperature?: number;
}

export interface ModelBackendOptions {
  expert?: () => ExpertOverrides;
  /** Where model files come from. Dev builds point this at a local server. */
  filesBaseUrl?: string;
  /** Dev: change what the phone reports (to act as a smaller phone). */
  mapDevice?: (snapshot: DeviceSnapshot) => DeviceSnapshot;
  /** Dev: runs before every load attempt; throwing fails that attempt. */
  beforeInit?: (request: LoadRequest) => void | Promise<void>;
  /** Ask for notification permission when the first download starts. */
  askForNotifications?: boolean;
}

interface TokenMeter {
  tokens(count: number): void;
  finished(): void;
}

/** Counts streamed tokens of every completion that runs on the context. */
class MeteredCompletionEngine extends LocalCompletionEngine {
  constructor(
    context: LlamaContext,
    private readonly meter: TokenMeter,
  ) {
    super(context);
  }

  async completion(
    params: ApiCompletionParams,
    callback?: (data: CompletionStreamData) => void,
  ): Promise<CompletionResult> {
    try {
      return await super.completion(params, data => {
        if (data.token) {
          this.meter.tokens(1);
        }
        callback?.(data);
      });
    } finally {
      this.meter.finished();
    }
  }
}

const GGUF_MAGIC_BASE64 = 'R0dVRg==';
const MODELS_DIR = `${RNFS.DocumentDirectoryPath}/models/antichat`;
/** Android's downloader writes here until the file is complete. */
const PART_SUFFIX = '.part';
/** Written beside a file once its SHA-256 matched. */
const VERIFIED_SUFFIX = '.verified';

const sizeOf = async (path: string): Promise<number> => {
  try {
    return Number((await RNFS.stat(path)).size) || 0;
  } catch {
    return 0;
  }
};

const unlinkQuietly = (path: string) =>
  RNFS.unlink(path).catch(() => undefined);

export class PocketPalModelBackend implements ModelBackend<LoadedContext> {
  /** Set by `createModelRuntime`; tokens feed the engine's speed calibration. */
  meter: TokenMeter = {tokens: () => undefined, finished: () => undefined};

  /**
   * The download group of a file: the id of its model, so the "finished"
   * notice waits for the weights and the projector. Set by the runtime.
   */
  groupOf: (file: CatalogFile) => string = file => file.repo;

  private generation = 0;
  private askedForNotifications = false;

  constructor(private readonly options: ModelBackendOptions = {}) {}

  // ---- files --------------------------------------------------------------

  /**
   * `Documents/models/antichat/<repo>/<revision>/<path>`. The revision is part
   * of the path, so a catalogue that pins a new commit never reuses old bytes.
   */
  pathFor(file: CatalogFile): string {
    return `${MODELS_DIR}/${file.repo}/${file.revision.slice(0, 12)}/${file.path}`;
  }

  urlFor(file: CatalogFile): string {
    const base = this.options.filesBaseUrl ?? MODEL_FILES_BASE_URL;
    return `${base}/${file.repo}/resolve/${file.revision}/${file.path}`;
  }

  async bytesOnDisk(file: CatalogFile): Promise<number> {
    const path = this.pathFor(file);
    const complete = await sizeOf(path);
    if (complete > 0) {
      return complete;
    }
    if (Platform.OS === 'android') {
      return sizeOf(path + PART_SUFFIX);
    }
    // iOS keeps a partial download inside the system's download service; the
    // native module knows how far it is.
    return nativeBytesFor(path).catch(() => 0);
  }

  async isVerified(file: CatalogFile): Promise<boolean> {
    const path = this.pathFor(file);
    try {
      const marker = await RNFS.readFile(path + VERIFIED_SUFFIX, 'utf8');
      return (
        marker.trim() === `${file.sha256}:${file.sizeBytes}` &&
        (await sizeOf(path)) === file.sizeBytes
      );
    } catch {
      return false;
    }
  }

  download(
    file: CatalogFile,
    onProgress: (receivedBytes: number, bytesPerSecond?: number) => void,
  ): DownloadTask {
    const destination = this.pathFor(file);
    let inner: FileDownload | null = null;
    let stopped = false;
    let paused = false;
    let lastBytes = -1;
    let lastTime = 0;
    let rate: number | undefined;

    const report = (bytes: number) => {
      const now = Date.now();
      if (lastBytes >= 0 && now > lastTime && bytes >= lastBytes) {
        const sample = ((bytes - lastBytes) * 1000) / (now - lastTime);
        // Smoothed, so the "about 4 min" in the UI does not jump around.
        rate = rate === undefined ? sample : rate * 0.7 + sample * 0.3;
      }
      lastBytes = bytes;
      lastTime = now;
      onProgress(bytes, rate);
    };

    const done = (async () => {
      await RNFS.mkdir(destination.substring(0, destination.lastIndexOf('/')));
      if (Platform.OS === 'ios') {
        // Same effect as upstream's excludeModelsFromBackup(), for our folder.
        await RNFS.mkdir(`${RNFS.DocumentDirectoryPath}/models`, {
          NSURLIsExcludedFromBackupKey: true,
        }).catch(() => undefined);
      }
      if (stopped) {
        throw new Error('Download stopped');
      }
      if (this.options.askForNotifications && !this.askedForNotifications) {
        this.askedForNotifications = true;
        // Not awaited: the download does not wait for the answer.
        requestNotificationPermission().catch(() => false);
      }
      const notice = downloadNotice();
      inner = startFileDownload(
        {
          url: this.urlFor(file),
          destination,
          totalBytes: file.sizeBytes,
          group: this.groupOf(file),
          notifyTitle: notice.title,
          notifyBody: notice.body,
        },
        report,
      );
      if (paused) {
        inner.pause();
      }
      await inner.done;
    })();
    done.catch(() => undefined);

    return {
      done,
      pause: () => {
        paused = true;
        rate = undefined;
        lastBytes = -1;
        inner?.pause();
      },
      resume: () => {
        paused = false;
        inner?.resume();
      },
      // Keeps the partial data (the contract of DownloadTask.cancel); the
      // engine calls `remove` when the bytes should go too.
      cancel: () => {
        stopped = true;
        inner?.stop();
      },
    };
  }

  async verify(
    file: CatalogFile,
    onProgress: (fraction: number) => void,
  ): Promise<boolean> {
    const path = this.pathFor(file);
    if ((await sizeOf(path)) !== file.sizeBytes) {
      return false;
    }
    if (file.path.toLowerCase().endsWith('.gguf')) {
      const head = await RNFS.read(path, 4, 0, 'base64').catch(() => null);
      if (head !== GGUF_MAGIC_BASE64) {
        return false;
      }
    }
    const digest = await sha256File(path, onProgress);
    if (digest !== file.sha256.toLowerCase()) {
      return false;
    }
    await RNFS.writeFile(
      path + VERIFIED_SUFFIX,
      `${file.sha256}:${file.sizeBytes}`,
      'utf8',
    );
    // The native side may still list the finished download.
    await forgetNativeDownload(path).catch(() => undefined);
    return true;
  }

  async remove(file: CatalogFile): Promise<void> {
    const path = this.pathFor(file);
    await forgetNativeDownload(path).catch(() => undefined);
    await Promise.all([
      unlinkQuietly(path),
      unlinkQuietly(path + PART_SUFFIX),
      unlinkQuietly(path + VERIFIED_SUFFIX),
    ]);
  }

  // ---- device -------------------------------------------------------------

  async readDevice(): Promise<DeviceSnapshot> {
    const snapshot = await readDeviceSnapshot();
    return this.options.mapDevice ? this.options.mapDevice(snapshot) : snapshot;
  }

  network(): NetworkStatus {
    return connectivity.status;
  }

  async freeStorageBytes(): Promise<number | null> {
    try {
      return await DeviceInfo.getFreeDiskStorage();
    } catch {
      return null;
    }
  }

  /**
   * "In front" is anything but `background`. iOS reports `inactive` while a
   * system prompt covers the app (the notification permission, for one); the
   * app is on screen then and may load.
   *
   * React Native's AppState alone is not enough on iOS: when the app returns
   * to the screen under such a prompt no "did become active" is posted and
   * AppState keeps saying `background`. So UIKit is asked directly, at once
   * and then once a second (timers do not run while the app is suspended).
   */
  waitUntilForeground(): Promise<void> {
    if (AppState.currentState !== 'background') {
      return Promise.resolve();
    }
    return new Promise(resolve => {
      let timer: ReturnType<typeof setInterval> | undefined;
      const finish = () => {
        subscription.remove();
        if (timer !== undefined) {
          clearInterval(timer);
        }
        resolve();
      };
      const subscription = AppState.addEventListener('change', state => {
        if (state !== 'background') {
          finish();
        }
      });
      const native = antichatNative;
      if (native?.applicationState) {
        const check = () => {
          native
            .applicationState?.()
            .then(state => {
              if (state !== 'background') {
                finish();
              }
            })
            .catch(() => undefined);
        };
        timer = setInterval(check, 1000);
        check();
      }
    });
  }

  /**
   * `os_proc_available_memory()` on iOS, `ActivityManager.MemoryInfo.availMem`
   * on Android. Throws when there is no reading (the iOS Simulator reports 0),
   * so the engine falls back to the launch-time budget.
   */
  async availableMemoryBytes(): Promise<number> {
    const bytes = antichatNative
      ? (await antichatNative.memoryInfo()).availableBytes
      : await NativeHardwareInfo.getAvailableMemory();
    if (!(bytes > 0)) {
      throw new Error('no available-memory reading');
    }
    return bytes;
  }

  // ---- contexts -----------------------------------------------------------

  async initContext(request: LoadRequest): Promise<LoadedContext> {
    const generation = ++this.generation;
    await this.options.beforeInit?.(request);

    const {attempt, model} = request;
    const weightsPath = this.pathFor(request.weights);
    // Whatever upstream had loaded goes first: two models never share memory.
    await modelStore.releaseContext(false).catch(() => undefined);

    const base = await modelStore.getEffectiveContextInitParams(weightsPath);
    const expert = this.options.expert?.() ?? {};
    const cpu = attempt.backend === 'cpu' || expert.gpuLayers === 0;
    // An expert may shrink the window, never grow it past what the policy
    // found to fit.
    const contextSize = Math.min(
      attempt.contextSize,
      expert.contextSize ?? attempt.contextSize,
    );
    const params = {
      ...base,
      model: weightsPath,
      n_ctx: contextSize,
      n_batch: Math.min(base.n_batch ?? 512, contextSize),
      n_ubatch: Math.min(base.n_ubatch ?? 512, contextSize),
      ...(expert.threads ? {n_threads: expert.threads} : {}),
      n_gpu_layers: cpu ? 0 : attempt.gpuLayers,
      no_gpu_devices: cpu,
      devices: cpu
        ? Platform.OS === 'android'
          ? ['CPU']
          : undefined
        : await gpuDevices(),
      // OpenCL only supports flash attention off (upstream's device options).
      ...(attempt.backend === 'opencl'
        ? {flash_attn_type: 'off' as const}
        : {}),
    };

    const context = await initLlama(params);
    let vision = false;
    try {
      if (request.projector && attempt.vision) {
        vision = await context.initMultimodal({
          path: this.pathFor(request.projector),
          use_gpu: !cpu,
          image_max_tokens: Math.min(
            modelStore.contextInitParams.image_max_tokens ?? 512,
            attempt.contextSize,
          ),
        });
        if (!vision) {
          throw new Error('The vision projector could not be initialised');
        }
      }
    } catch (error) {
      await context.release().catch(() => undefined);
      throw error;
    }

    const storeModel = this.storeModelFor(request, weightsPath);
    const loaded: LoadedContext = {
      context,
      modelId: model.id,
      storeModelId: storeModel.id,
    };
    // An attempt the engine gave up on (timeout) must not become the active
    // context; the engine releases it through `releaseContext`.
    if (generation === this.generation) {
      runInAction(() => {
        modelStore.context = context;
        modelStore.engine = new MeteredCompletionEngine(context, this.meter);
        modelStore.activeRemoteBinding = undefined;
        // What was really loaded (window, batch, threads), not upstream's
        // defaults: the request seam sizes the context fitting from it.
        modelStore.activeContextSettings = createContextInitParams({
          ...base,
          n_ctx: params.n_ctx,
          n_batch: params.n_batch,
          n_ubatch: params.n_ubatch,
          n_threads: params.n_threads ?? base.n_threads,
          n_gpu_layers: params.n_gpu_layers,
        });
        modelStore.isMultimodalActive = vision;
        modelStore.setActiveModel(storeModel.id);
      });
    }
    return loaded;
  }

  async releaseContext(loaded: LoadedContext): Promise<void> {
    if (modelStore.context === loaded.context) {
      // Upstream's release also stops a running generation first.
      await modelStore.releaseContext(true);
      return;
    }
    await loaded.context.releaseMultimodal().catch(() => undefined);
    await loaded.context.release();
  }

  async releaseProjector(loaded: LoadedContext): Promise<void> {
    await loaded.context.releaseMultimodal();
    if (modelStore.context === loaded.context) {
      runInAction(() => {
        modelStore.isMultimodalActive = false;
        modelStore.activeProjectionModelId = undefined;
      });
    }
  }

  /** The upstream `Model` record that stands for a catalogue model. */
  private storeModelFor(request: LoadRequest, weightsPath: string): Model {
    const id = `antichat/${request.model.id}`;
    const existing = modelStore.models.find(m => m.id === id);
    if (existing) {
      runInAction(() => {
        existing.fullPath = weightsPath;
        existing.name = request.model.displayName;
        existing.size = request.weights.sizeBytes;
        existing.isDownloaded = true;
      });
      return existing;
    }
    const defaults = getLocalModelDefaultSettings();
    const record: Model = {
      id,
      author: request.weights.repo.split('/')[0] ?? '',
      repo: request.weights.repo.split('/')[1],
      name: request.model.displayName,
      size: request.weights.sizeBytes,
      params: 0,
      isDownloaded: true,
      downloadUrl: '',
      hfUrl: `https://huggingface.co/${request.weights.repo}`,
      progress: 100,
      filename: request.weights.path,
      fullPath: weightsPath,
      isLocal: true,
      origin: ModelOrigin.LOCAL,
      defaultChatTemplate: {...defaults.chatTemplate},
      chatTemplate: {...defaults.chatTemplate},
      defaultStopWords: [...(defaults.completionParams?.stop ?? [])],
      stopWords: [...(defaults.completionParams?.stop ?? [])],
      defaultCompletionSettings: defaults.completionParams,
      completionSettings: {...defaults.completionParams},
    };
    runInAction(() => {
      modelStore.models.push(record);
    });
    return modelStore.models.find(m => m.id === id) ?? record;
  }
}

/** The GPU device llama.rn should use; undefined lets it choose (Metal on iOS). */
async function gpuDevices(): Promise<string[] | undefined> {
  if (Platform.OS !== 'android') {
    return undefined;
  }
  const devices = await getBackendDevicesInfo().catch(() => []);
  const gpu = (devices ?? []).find(d => d.type === 'gpu');
  if (!gpu?.deviceName) {
    throw new Error('No GPU device is available to llama.rn');
  }
  return [gpu.deviceName];
}

// ---- wiring ---------------------------------------------------------------

export interface ModelRuntimeOptions extends ModelBackendOptions {
  /** Dev: use this catalogue instead of the bundled one. */
  bundled?: Catalog;
  /** Catalogue address; defaults to the production placeholder. */
  catalogUrl?: string;
  /** Pinned Ed25519 keys (base64); defaults to the production placeholder. */
  catalogPublicKeys?: readonly string[];
  /** Dev: told whether the "ready" notification was shown (app in front: no). */
  onReadyNotice?: (modelId: string, shown: boolean) => void;
}

export interface ModelRuntime {
  engine: ModelEngine<LoadedContext>;
  backend: PocketPalModelBackend;
  catalogStore: CatalogStore;
  /** Connect to the phone and initialise the engine. Idempotent. */
  start(): Promise<void>;
  stop(): void;
}

const fetchText: FetchText = async url => {
  const response = await fetch(url, {headers: {'Cache-Control': 'no-cache'}});
  return {status: response.status, text: await response.text()};
};

export function createModelRuntime(
  options: ModelRuntimeOptions = {},
): ModelRuntime {
  const backend = new PocketPalModelBackend(options);
  const catalogStore = new CatalogStore({
    bundled: options.bundled ?? bundledCatalog,
    storage: AsyncStorage,
    appVersion: DeviceInfo.getVersion(),
    url: options.catalogUrl ?? CATALOG_URL,
    fetchText,
    verifier: ed25519Verifier(options.catalogPublicKeys ?? CATALOG_PUBLIC_KEYS),
  });
  const engine = new ModelEngine<LoadedContext>({
    backend,
    storage: AsyncStorage,
    catalogStore,
  });
  backend.groupOf = file =>
    catalogStore.catalog.models.find(
      model =>
        model.files.some(f => f.sha256 === file.sha256) ||
        model.projector?.sha256 === file.sha256,
    )?.id ?? file.repo;
  backend.meter = {
    tokens: count => engine.noteGeneratedTokens(count),
    finished: () => {
      engine.noteGenerationFinished().catch(() => undefined);
    },
  };

  const cleanups: Array<() => void> = [];
  let starting: Promise<void> | null = null;

  const pressure = (level: MemoryPressure) => {
    engine
      .onMemoryPressure(level, {
        generating: modelStore.inferencing || modelStore.isStreaming,
        aux: [],
      })
      .catch(() => undefined);
  };

  /** "Your assistant is ready" when a download ends while the app is away. */
  const watchForReady = () => {
    const before = new Map<string, string>();
    return engine.subscribe(() => {
      for (const view of engine.models) {
        const was = before.get(view.id);
        const now = view.state.status;
        before.set(view.id, now);
        if (was === 'verifying' && (now === 'ready' || now === 'loading')) {
          notifyModelReady(view.id)
            .then(shown => options.onReadyNotice?.(view.id, shown))
            .catch(() => undefined);
        }
      }
    });
  };

  const start = async () => {
    // The engine owns loading and unloading; upstream's background auto-release
    // would unload behind its back and reload through `Alert`-raising paths.
    modelStore.disableAutoRelease('antichat-model-engine');
    await startConnectivity();
    cleanups.push(
      connectivity.subscribe(() => {
        engine.onNetworkChange().catch(() => undefined);
      }),
    );

    // iOS: UIApplicationDidReceiveMemoryWarning arrives as an AppState event.
    // Android has no such event in React Native; our module forwards
    // onTrimMemory / onLowMemory.
    if (Platform.OS === 'ios') {
      const subscription = AppState.addEventListener('memoryWarning', () =>
        pressure('critical'),
      );
      cleanups.push(() => subscription.remove());
    } else {
      const subscription = antichatNativeEvents()?.addListener(
        'onMemoryPressure',
        (event: {level: MemoryPressure}) => pressure(event.level),
      );
      cleanups.push(() => subscription?.remove());
    }
    cleanups.push(watchForReady());

    await engine.initialize();

    // A newer signed catalogue is adopted for the next launch.
    if (connectivity.online && (await catalogStore.shouldRefresh())) {
      catalogStore.refresh().catch(() => undefined);
    }
  };

  return {
    engine,
    backend,
    catalogStore,
    start: () => {
      starting ??= start();
      return starting;
    },
    stop: () => {
      cleanups.splice(0).forEach(cleanup => cleanup());
      starting = null;
    },
  };
}

/** The Android emulator reaches the Mac at 10.0.2.2, not 127.0.0.1. */
export function hostForPlatform(url?: string): string | undefined {
  if (!url || Platform.OS !== 'android') {
    return url;
  }
  return url.replace(
    /^(https?:\/\/)(127\.0\.0\.1|localhost)(?=[:/]|$)/,
    '$110.0.2.2',
  );
}

let sharedRuntime: ModelRuntime | null = null;
let devRuntimeOptions: ModelRuntimeOptions = {};

/**
 * Debug builds: options for the shared runtime (a local file server in place
 * of Hugging Face, a smaller pretend phone). Must be called before the first
 * `sharedModelRuntime()`; see `engine/dev/index.tsx`.
 */
export function setDevRuntimeOptions(options: ModelRuntimeOptions): void {
  // Not `__DEV__`: debug builds with embedded JS run with it off.
  if (isDevBuild() && !sharedRuntime) {
    devRuntimeOptions = {
      ...options,
      filesBaseUrl: hostForPlatform(options.filesBaseUrl),
    };
  }
}

/**
 * The app's one model runtime. `installEngine()` starts it; the model port
 * (`adapters/index.ts`) and M6's coordinator read the same instance. It never
 * asks for notification permission by itself: the first-run card does.
 */
export function sharedModelRuntime(): ModelRuntime {
  sharedRuntime ??= createModelRuntime({
    ...devRuntimeOptions,
    expert: readExpertOverrides,
  });
  return sharedRuntime;
}

/** Settings > Advanced (M6). Empty unless expert mode is on. */
function readExpertOverrides(): ExpertOverrides {
  try {
    return require('../ui/settings/store').settingsStore.expertOverrides();
  } catch {
    return {};
  }
}
