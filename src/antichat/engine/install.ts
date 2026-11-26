/**
 * The one call that switches the AntiChat engine on.
 *
 * Called by the AntiChat root only (`app/AntiChatApp.tsx`). A build showing
 * upstream's UI never calls it, so no provider is registered, no tool is
 * replaced and the app behaves exactly as upstream.
 *
 * Order, and why:
 *  1. schemas      memory and projects add their migration steps
 *                  before antichat.db is opened for the first time;
 *  2. connectivity the first reading, so nothing below starts "online" by
 *                  default;
 *  3. store        antichat.db open, migrated and in step with upstream;
 *  4. prompt       system prompt, skills, context fitting; the seam learns
 *                  the device class and the chat's flags from the store;
 *  5. tools        built-in tools become talents, selection joins the seam;
 *  6. memory       project and memory providers and tools (keyword search;
 *                  the embedder joins when `embeddings` is on);
 *  7. models       device classified, model selected (downloads start only
 *                  when the UI asks). Last, because it is the slow step and
 *                  nothing above needs its result to register.
 *
 * Request providers run by their own `order`, not by install order:
 * system prompt (10) → skills (20) → tools (30) → project (40) →
 * memory (50) → context fitting (900, a transform).
 *
 * Not installed in the first version: the files engine (`engine/files/`,
 * `installFilesEngine`) and the embedding model. Both are complete behind
 * their own install calls; see `docs/antichat/m10-files-engine.md`.
 */
import type {ConversationAdapter} from '../adapters/conversation';
import type {ModelRuntime} from '../adapters/model';
import type {EmbeddingRuntime} from './embeddingRuntime';
import type {MemoryEngine} from './memory/engine';
import type {DeviceClass as PromptDeviceClass} from './prompt/types';

export const ENGINE_INSTALL_ORDER = [
  'schemas',
  'connectivity',
  'store',
  'prompt',
  'tools',
  'memory',
  'models',
] as const;
export type EngineStep = (typeof ENGINE_INSTALL_ORDER)[number];

export interface InstalledEngine {
  readonly models: ModelRuntime;
  readonly conversations: ConversationAdapter;
  readonly memory: MemoryEngine;
  readonly embedding: EmbeddingRuntime;
  /** Steps that failed; the others are installed. */
  readonly failed: Partial<Record<EngineStep, string>>;
  uninstall(): void;
}

export interface EngineInstallOptions {
  /** Dev: model runtime options (local file server, device override). */
  modelRuntime?: () => ModelRuntime;
  /**
   * Fetch and use the embedding model for memory retrieval (default false:
   * the first version searches memories by keyword and downloads nothing
   * beyond the chat model).
   */
  embeddings?: boolean;
  /** Told as each step starts (dev log, tests). */
  onStep?: (step: EngineStep) => void;
}

/** Settings > Advanced: the temperature an expert set (M6's store). */
function expertSampling(): {temperature?: number} {
  try {
    const {temperature} = (
      require('../ui/settings/store') as typeof import('../ui/settings/store')
    ).settingsStore.expertOverrides();
    return temperature !== undefined ? {temperature} : {};
  } catch {
    return {};
  }
}

let installing: Promise<InstalledEngine> | null = null;
let current: InstalledEngine | null = null;

/** The installed engine, or null before `installEngine()` has finished. */
export function getEngine(): InstalledEngine | null {
  return current;
}

/** Install everything once; later calls return the same engine. */
export function installEngine(
  options: EngineInstallOptions = {},
): Promise<InstalledEngine> {
  installing ??= install(options).catch(error => {
    installing = null;
    throw error;
  });
  return installing;
}

/** Tests and hot reload. */
export function uninstallEngine(): void {
  current?.uninstall();
  current = null;
  installing = null;
}

async function install(
  options: EngineInstallOptions,
): Promise<InstalledEngine> {
  const failed: Partial<Record<EngineStep, string>> = {};
  const removers: Array<() => void> = [];
  const step = async <T>(
    name: EngineStep,
    work: () => T | Promise<T>,
  ): Promise<T | undefined> => {
    options.onStep?.(name);
    try {
      return await work();
    } catch (error) {
      // One broken part must not take chat down with it.
      failed[name] = String(error);
      console.warn(`[antichat] engine step "${name}" failed`, error);
      return undefined;
    }
  };

  const {connectivity, startConnectivity} =
    require('../adapters/connectivity') as typeof import('../adapters/connectivity');
  const models =
    options.modelRuntime?.() ??
    (
      require('../adapters/model') as typeof import('../adapters/model')
    ).sharedModelRuntime();
  const conversations = (
    require('../adapters/conversation') as typeof import('../adapters/conversation')
  ).conversationAdapter();
  const promptClass = (): PromptDeviceClass | undefined => {
    const deviceClass = models.engine.deviceClass;
    return deviceClass === 'E' ? 'D' : (deviceClass ?? undefined);
  };
  const online = {
    isOnline: () => connectivity.online,
    subscribe: (listener: (online: boolean) => void) =>
      connectivity.subscribe(() => listener(connectivity.online)),
  };

  await step('schemas', () => {
    require('./memory/install').registerMemorySchemas();
  });
  await step('connectivity', () => startConnectivity());
  const store = await step('store', () => conversations.store());

  await step('prompt', () => {
    const {getChatFlags} =
      require('./store/read') as typeof import('./store/read');
    removers.push(
      require('./prompt/install').installPromptEngine({
        environment: {
          deviceClass: promptClass,
          chatFlags: store
            ? (sessionId: string) => getChatFlags(store.db, sessionId)
            : undefined,
          sampling: expertSampling,
        },
      }),
    );
    // Offline chats are known before the first request of this run.
    (require('./offline') as typeof import('./offline'))
      .loadOfflineChats()
      .catch(() => undefined);
  });

  await step('tools', () => {
    removers.push(
      require('./tools/install').installToolEngine({connectivity: online}),
    );
  });

  const embedding = (
    require('./embeddingRuntime') as typeof import('./embeddingRuntime')
  ).createEmbeddingRuntime(models, {isOnline: online.isOnline});
  removers.push(embedding.dispose);

  const memory = await step('memory', async () => {
    if (!store) {
      throw new Error('antichat.db is not open');
    }
    const memoryInstall =
      require('./memory/install') as typeof import('./memory/install');
    const engine = await memoryInstall.installMemoryEngine({
      db: store.db,
      chats: conversations,
      embedding: options.embeddings ? embedding.service : undefined,
      deviceClass: promptClass,
    });
    removers.push(memoryInstall.uninstallMemoryEngine);
    // Rows about a deleted chat (use records, digests) go at once.
    removers.push(
      store.onSessionDeleted(() => {
        engine.store.purge().catch(() => undefined);
      }),
    );
    return engine;
  });

  await step('models', async () => {
    await models.start();
    removers.push(models.stop);
    // The embedding file follows the chat model: fetched once a chat model
    // is in place, so the first download the user waits for is the chat one.
    const fetchWhenReady = () => {
      if (options.embeddings && models.engine.activeModelId) {
        embedding.ensureFile().catch(() => undefined);
      }
    };
    removers.push(models.engine.subscribe(fetchWhenReady));
    fetchWhenReady();
  });

  current = {
    models,
    conversations,
    memory: memory as MemoryEngine,
    embedding,
    failed,
    uninstall: () => {
      removers
        .splice(0)
        .reverse()
        .forEach(remove => {
          try {
            remove();
          } catch {
            // Uninstalling is best effort.
          }
        });
    },
  };
  return current;
}
