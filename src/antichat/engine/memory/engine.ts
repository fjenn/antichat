/**
 * Assembles the memory and projects engine from its parts. No app store is
 * imported here, so the whole thing runs in Jest and in the real-model
 * checks exactly as it runs on the phone; `install.ts` binds it to the app.
 */
import type {TalentEngine} from '../../../services/talents/types';
import {createProjectProvider} from '../projects/provider';
import {ProjectStore} from '../projects/ProjectStore';
import type {ProjectChats} from '../projects/types';
import type {
  DeviceClass,
  PreparedRequest,
  RequestProvider,
} from '../prompt/types';
import type {Db} from '../store/driver';
import {createChatResolver, type ChatResolver} from './chatScope';
import {DigestStore} from './digest';
import type {EmbeddingService} from './embeddings/service';
import {VectorStore} from './embeddings/vectorStore';
import {MemoryStore} from './MemoryStore';
import {createMemoryPort, type MemoryPort} from './port';
import {createMemoryProvider} from './provider';
import {attributeMemories, memoryBudgetFor} from './retrieval';
import {MemoryScheduler, type ModelLease, type PassResult} from './scheduler';
import {
  SAVE_MEMORY,
  createForgetMemoryTool,
  createSaveMemoryTool,
  createSearchChatsTool,
  type ToolChatContext,
} from './tools';
import type {MemoryRequestMeta} from './types';
import {MemoryWriter, type SaveResult} from './writer';

export interface MemoryEngineOptions {
  db: Db;
  /** M3's chat operations, for moving chats in and out of projects. */
  chats?: ProjectChats;
  /** The embedding model's lifecycle; absent = keyword retrieval only. */
  embedding?: EmbeddingService;
  /** Takes the chat model for a background job if it is free. */
  acquireModel?: () => ModelLease | null;
  deviceClass?: () => DeviceClass | undefined;
  /** The chat on screen (tools are called from it). */
  currentSessionId?: () => string | null | undefined;
  /** The user's message being answered (for the tool-side screen). */
  currentUserText?: () => string | undefined;
  /** Context window of the loaded model, for sizing tool results. */
  nCtx?: () => number | undefined;
  now?: () => number;
  /** A chat is read by the idle pass once quiet this long (ms). */
  quietMs?: number;
}

export interface ReplyInfo {
  sessionId?: string | null;
  /** Upstream id of the assistant message. */
  messageId?: string | null;
  userText: string;
  reply: string;
  /** `PreparedRequest.meta` of the request that produced the reply. */
  meta?: PreparedRequest['meta'];
  /** Names of the tools called during the reply. */
  toolsCalled?: string[];
}

export interface ReplyOutcome {
  /** Memories the answer drew on (ids), now marked on the use record. */
  cited: string[];
  /** Facts saved because the user asked and the model did not call the tool. */
  captured: SaveResult[] | null;
}

export interface MemoryEngine {
  readonly store: MemoryStore;
  readonly writer: MemoryWriter;
  readonly digests: DigestStore;
  readonly vectors: VectorStore;
  readonly projects: ProjectStore;
  readonly scheduler: MemoryScheduler;
  readonly resolveChat: ChatResolver;
  /** For the manage screen, the notice and the chip. */
  readonly port: MemoryPort;
  /** Register with `registerRequestProvider`. */
  readonly providers: RequestProvider[];
  /** Register with upstream's `talentRegistry`. */
  readonly tools: TalentEngine[];
  /** Applies both schemas and loads settings. */
  init(): Promise<void>;
  /** Call when a reply is finished. */
  afterReply(info: ReplyInfo): Promise<ReplyOutcome>;
  /** Call when the user leaves a chat (opens another, starts a new one). */
  leaveChat(sessionId: string | null | undefined): Promise<PassResult>;
  /** Call after about a minute without activity while the model is loaded. */
  idle(): Promise<PassResult>;
}

export function createMemoryEngine(options: MemoryEngineOptions): MemoryEngine {
  const {db} = options;
  const now = options.now ?? Date.now;
  const store = new MemoryStore({db, now});
  const vectors = new VectorStore(db);
  const digests = new DigestStore(db, now);
  const projects = new ProjectStore({db, chats: options.chats, now});
  const resolveChat = createChatResolver(db);
  const embedding = options.embedding;
  // Writes and the idle pass may load the model to index; a send only uses
  // it where the device policy allows a query-time load.
  const writer = new MemoryWriter({
    store,
    vectors,
    embedder: embedding?.provider('index'),
  });
  const scheduler = new MemoryScheduler({
    db,
    store,
    writer,
    digests,
    resolveChat,
    acquireModel: options.acquireModel ?? (() => null),
    deviceClass: options.deviceClass,
    now,
    quietMs: options.quietMs,
  });

  const toolContext = async (): Promise<ToolChatContext> => {
    const sessionId = options.currentSessionId?.() ?? null;
    const chat = await resolveChat(sessionId);
    const nCtx = options.nCtx?.() ?? 8192;
    return {
      sessionId,
      temporary: chat.temporary,
      readOnly: chat.readOnly,
      scope: chat.scope,
      isolatedProjectIds: chat.isolatedProjectIds,
      resultChars: nCtx < 6000 ? 600 : memoryBudgetFor(nCtx).digestTokens * 3,
      userText: options.currentUserText?.(),
    };
  };
  // The tool path never loads the embedding model: the chat model is busy.
  const toolWriter = new MemoryWriter({store});
  const tools: TalentEngine[] = [
    createSaveMemoryTool({store, writer: toolWriter, context: toolContext}),
    createForgetMemoryTool({store, writer: toolWriter, context: toolContext}),
    createSearchChatsTool({db, store, context: toolContext}),
  ];

  const providers: RequestProvider[] = [
    createProjectProvider({projects}),
    createMemoryProvider({
      store,
      resolveChat,
      digests,
      vectors,
      embedder: embedding?.provider('query'),
    }),
  ];

  let ready: Promise<void> | null = null;
  const init = (): Promise<void> => {
    if (!ready) {
      ready = (async () => {
        await store.init();
        await projects.init();
      })();
    }
    return ready;
  };

  return {
    store,
    writer,
    digests,
    vectors,
    projects,
    scheduler,
    resolveChat,
    port: createMemoryPort(store, writer, init),
    providers,
    tools,
    init,
    async afterReply(info) {
      const outcome: ReplyOutcome = {cited: [], captured: null};
      const memory = info.meta?.memory as MemoryRequestMeta | undefined;
      if (memory?.useId) {
        outcome.cited = attributeMemories(
          memory.injected,
          info.userText,
          info.reply,
        );
        await store.confirmUse(memory.useId, {
          messageId: info.messageId,
          citedIds: outcome.cited,
        });
      }
      outcome.captured = await scheduler.captureExplicit({
        sessionId: info.sessionId,
        userText: info.userText,
        toolSaved: (info.toolsCalled ?? []).includes(SAVE_MEMORY),
      });
      return outcome;
    },
    leaveChat: sessionId =>
      scheduler.runPass({
        leaving: sessionId ?? null,
        current: options.currentSessionId?.() ?? null,
      }),
    idle: () =>
      scheduler.runPass({current: options.currentSessionId?.() ?? null}),
  };
}
