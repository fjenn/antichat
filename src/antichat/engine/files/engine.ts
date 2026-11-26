/**
 * The files engine: one object that owns attachments from the moment a
 * file is picked to the moment the model reads it.
 */
import type {TalentEngine} from '../../../services/talents/types';
import type {EmbeddingService} from '../memory/embeddings/service';
import type {DeviceClass, RequestProvider} from '../prompt/types';
import type {Db} from '../store/driver';
import {randomId} from '../store/ConversationStore';
import {FilesStore, type FileRow} from './FilesStore';
import {ingestFile, type IngestResult} from './ingest';
import {fileBudgetFor, type FileBudget} from './limits';
import type {FileIo} from './native';
import {createFilesProvider} from './provider';
import {createSearchFilesTool, createSqlQueryTool} from './tools';

export interface FilesEngineOptions {
  db: Db;
  io: FileIo;
  embedding?: EmbeddingService;
  deviceClass?: () => DeviceClass | undefined;
  nCtx?: () => number | undefined;
  visionActive?: () => boolean;
  currentSessionId?: () => string | null | undefined;
  charsPerToken?: () => number;
  newId?: () => string;
}

export interface AddFileInput {
  uri: string;
  name: string;
  mimeType?: string | null;
  sizeBytes?: number | null;
  /** The chat it is attached in; null = the composer of a new chat. */
  sessionId: string | null;
  projectId?: string | null;
  /** Copy the file into the app's storage first (picker and share URIs). */
  keep?: boolean;
}

export type FilesEvent =
  | {type: 'added'; file: FileRow}
  | {type: 'progress'; fileId: string; fraction: number}
  | {type: 'ready' | 'failed'; file: FileRow}
  | {type: 'removed'; fileId: string; sessionId: string | null}
  | {type: 'sql'; sql: string; ok: boolean; text: string};

export interface FilesEngine {
  readonly store: FilesStore;
  readonly providers: RequestProvider[];
  readonly tools: TalentEngine[];
  budget(): FileBudget;
  /** Registers the file and prepares it; resolves when it is ready or failed. */
  add(input: AddFileInput): Promise<IngestResult>;
  /** Long pasted text as a text attachment. */
  addText(
    text: string,
    sessionId: string | null,
    name?: string,
  ): Promise<IngestResult>;
  remove(fileId: string): Promise<void>;
  removeForSession(sessionId: string): Promise<void>;
  /** URIs of the chat's unsent images for the vision model. */
  imageUris(sessionId: string | null): Promise<string[]>;
  subscribe(listener: (event: FilesEvent) => void): () => void;
}

export function createFilesEngine(options: FilesEngineOptions): FilesEngine {
  const store = new FilesStore(options.db);
  const listeners = new Set<(event: FilesEvent) => void>();
  const emit = (event: FilesEvent) =>
    listeners.forEach(listener => {
      try {
        listener(event);
      } catch {
        // A listener must not break ingestion.
      }
    });
  const budget = () =>
    fileBudgetFor(options.deviceClass?.(), options.nCtx?.() ?? 8192);
  const visionActive = () => options.visionActive?.() ?? false;
  const toolOptions = {
    store,
    budget,
    currentSessionId: () => options.currentSessionId?.() ?? null,
    // No embedder: the chat model is generating while a tool runs.
    onSql: (event: {sql: string; ok: boolean; text: string}) =>
      emit({type: 'sql', ...event}),
  };

  const add = async (input: AddFileInput): Promise<IngestResult> => {
    const id = (options.newId ?? randomId)();
    let uri = input.uri;
    if (input.keep && options.io.keep) {
      uri = await options.io.keep(input.uri, input.name);
    }
    const result = await ingestFile(
      {...input, id, uri},
      {
        store,
        io: options.io,
        budget,
        embedding: options.embedding,
        visionActive,
        charsPerToken: options.charsPerToken,
        onProgress: (fileId, fraction) =>
          emit({type: 'progress', fileId, fraction}),
      },
    );
    emit({
      type: result.file.status === 'ready' ? 'ready' : 'failed',
      file: result.file,
    });
    return result;
  };

  return {
    store,
    providers: [
      createFilesProvider({
        store,
        embedder: options.embedding?.provider('query'),
        visionActive,
      }),
    ],
    tools: [
      createSearchFilesTool(toolOptions),
      createSqlQueryTool(toolOptions),
    ],
    budget,
    add,
    async addText(text, sessionId, name = 'Pasted text.txt') {
      if (!options.io.writeText) {
        throw new Error('This build cannot store pasted text');
      }
      const uri = await options.io.writeText(name, text);
      return add({
        uri,
        name,
        mimeType: 'text/plain',
        sizeBytes: text.length,
        sessionId,
      });
    },
    async remove(fileId) {
      const file = await store.remove(fileId);
      if (file) {
        await options.io.remove?.(file.uri);
        emit({type: 'removed', fileId, sessionId: file.sessionId});
      }
    },
    async removeForSession(sessionId) {
      for (const file of await store.removeForSession(sessionId)) {
        await options.io.remove?.(file.uri);
      }
    },
    async imageUris(sessionId) {
      if (!visionActive()) {
        return [];
      }
      return (await store.list(sessionId))
        .filter(
          file =>
            file.status === 'ready' &&
            file.kind === 'image' &&
            file.messageId === null,
        )
        .slice(-budget().maxImages)
        .map(file => file.uri);
    },
    subscribe(listener) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
  };
}
