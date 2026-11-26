/**
 * The real embedder: EmbeddingGemma in a second llama.rn context, behind
 * the memory engine's `EmbeddingService` (and, through it, file retrieval).
 *
 * This file only binds that service to the phone:
 *  - which file (the catalogue's `embedding` entry, stored and verified like
 *    any model file, so it is downloaded once and survives app updates);
 *  - whether it may load now (device class, free memory read at that
 *    moment, chat model busy) — the per-class budget lives in
 *    `memory/embeddings/service.ts`;
 *  - when it must go: memory warning, app in the background.
 */
import {AppState, Platform} from 'react-native';

import {modelStore} from '../../store';
import type {ModelRuntime} from '../adapters/model';
import {
  EMBEDDING_GEMMA_300M,
  type EmbeddingModelSpec,
} from './memory/embeddings/catalog';
import {loadLlamaRnContext} from './memory/embeddings/llamaEmbedder';
import {
  createEmbeddingService,
  embeddingPolicyFor,
  type EmbeddingDeviceClass,
  type EmbeddingService,
} from './memory/embeddings/service';
import type {CatalogEmbedding} from './models/catalog/types';

export type EmbeddingFileState =
  | 'unavailable' // not in the catalogue, or the class never runs it
  | 'missing'
  | 'downloading'
  | 'ready'
  | 'failed';

export interface EmbeddingRuntime {
  readonly service: EmbeddingService;
  readonly spec: EmbeddingModelSpec;
  fileState(): EmbeddingFileState;
  /**
   * Fetches and verifies the file if this phone uses it and it is not there
   * yet. Resolves true when the file is ready. Single-flight; never throws.
   */
  ensureFile(): Promise<boolean>;
  dispose(): void;
}

/** The catalogue entry laid over the engine's built-in description. */
export function specFromCatalog(
  entry: CatalogEmbedding | undefined,
): EmbeddingModelSpec {
  if (!entry) {
    return EMBEDDING_GEMMA_300M;
  }
  return {
    ...EMBEDDING_GEMMA_300M,
    id: entry.id,
    filename: entry.file.path,
    source: `https://huggingface.co/${entry.file.repo}`,
    sizeBytes: entry.file.sizeBytes,
    ramBytes: entry.ramBytes,
    nativeDims: entry.nativeDims,
    dims: entry.dims,
    nCtx: entry.contextSize,
    verified: true,
  };
}

export function createEmbeddingRuntime(
  runtime: Pick<ModelRuntime, 'engine' | 'backend' | 'catalogStore'>,
  options: {isOnline?: () => boolean} = {},
): EmbeddingRuntime {
  const entry = () => runtime.catalogStore.catalog.embedding;
  const spec = specFromCatalog(entry());
  const deviceClass = (): EmbeddingDeviceClass =>
    runtime.engine.deviceClass ?? 'B';
  let state: EmbeddingFileState = entry() ? 'missing' : 'unavailable';
  let path: string | null = null;
  let fetching: Promise<boolean> | null = null;

  const resolvePath = async (): Promise<string | null> => {
    if (path) {
      return path;
    }
    const file = entry()?.file;
    if (!file) {
      return null;
    }
    if (await runtime.backend.isVerified(file)) {
      path = runtime.backend.pathFor(file);
      state = 'ready';
    }
    return path;
  };

  const service = createEmbeddingService({
    spec,
    modelPath: resolvePath,
    loader: loadLlamaRnContext,
    deviceClass,
    availableMemory: () =>
      runtime.backend.availableMemoryBytes().catch(() => null),
    isChatBusy: () => modelStore.inferencing || modelStore.isStreaming,
  });

  const ensureFile = (): Promise<boolean> => {
    fetching ??= (async () => {
      const file = entry()?.file;
      if (!file || !embeddingPolicyFor(deviceClass()).allowed) {
        state = 'unavailable';
        return false;
      }
      if (await resolvePath()) {
        return true;
      }
      if (options.isOnline && !options.isOnline()) {
        return false;
      }
      state = 'downloading';
      try {
        if ((await runtime.backend.bytesOnDisk(file)) !== file.sizeBytes) {
          await runtime.backend.download(file, () => undefined).done;
        }
        if (!(await runtime.backend.verify(file, () => undefined))) {
          await runtime.backend.remove(file);
          state = 'failed';
          return false;
        }
        return (await resolvePath()) !== null;
      } catch (error) {
        console.warn('[antichat] embedding model download failed', error);
        state = 'failed';
        return false;
      }
    })().finally(() => {
      fetching = null;
    });
    return fetching;
  };

  const release = () => {
    service.release().catch(() => undefined);
  };
  const subscriptions = [
    AppState.addEventListener('change', next => {
      if (next === 'background') {
        release();
      }
    }),
    ...(Platform.OS === 'ios'
      ? [AppState.addEventListener('memoryWarning', release)]
      : []),
  ];

  return {
    service,
    spec,
    fileState: () => state,
    ensureFile,
    dispose: () => {
      subscriptions.forEach(subscription => subscription.remove());
      release();
    },
  };
}
