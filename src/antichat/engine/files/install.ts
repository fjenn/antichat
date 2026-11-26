/**
 * Binds the files engine to the app. Called by `engine/install.ts` only.
 */
import {talentRegistry} from '../../../services/talents/TalentRegistry';
import {chatSessionStore, modelStore} from '../../../store';
import type {EmbeddingService} from '../memory/embeddings/service';
import {familyProfile} from '../prompt/modelFamily';
import {registerRequestProvider} from '../prompt/registry';
import {resolveSeamRuntime} from '../prompt/seam';
import type {DeviceClass} from '../prompt/types';
import type {ConversationStore} from '../store/ConversationStore';
import type {Db} from '../store/driver';
import {createFilesEngine, type FilesEngine} from './engine';
import {createNativeFileIo, type FileIo} from './native';
import {createFilesPort, type AntichatFilesPort} from './port';

export interface FilesInstallOptions {
  db: Db;
  store?: Pick<ConversationStore, 'onSessionDeleted'>;
  embedding?: EmbeddingService;
  deviceClass?: () => DeviceClass | undefined;
  /** Tests: file access without native modules. */
  io?: FileIo;
}

export interface InstalledFiles {
  readonly engine: FilesEngine;
  readonly port: AntichatFilesPort;
}

let installed: (InstalledFiles & {remove: () => void}) | null = null;

/** The installed files engine and its port, for the UI adapter. */
export function getFilesEngine(): InstalledFiles | null {
  return installed;
}

export async function installFilesEngine(
  options: FilesInstallOptions,
): Promise<InstalledFiles> {
  if (installed) {
    return installed;
  }
  const engine = createFilesEngine({
    db: options.db,
    io: options.io ?? createNativeFileIo(),
    embedding: options.embedding,
    deviceClass: options.deviceClass,
    nCtx: () => resolveSeamRuntime().nCtx,
    charsPerToken: () =>
      familyProfile(resolveSeamRuntime().family).charsPerToken,
    visionActive: () => !!modelStore.isMultimodalActive,
    currentSessionId: () => chatSessionStore.activeSessionId,
  });
  engine.tools.forEach(tool => talentRegistry.register(tool));
  const removers = engine.providers.map(provider =>
    registerRequestProvider(provider),
  );
  if (options.store) {
    removers.push(
      options.store.onSessionDeleted(sessionId => {
        engine.removeForSession(sessionId).catch(() => undefined);
      }),
    );
  }
  installed = {
    engine,
    port: createFilesPort(engine),
    remove: () => removers.forEach(remove => remove()),
  };
  return installed;
}

/** Removes the provider and the watcher again (tests, hot reload). */
export function uninstallFilesEngine(): void {
  installed?.remove();
  installed = null;
}
