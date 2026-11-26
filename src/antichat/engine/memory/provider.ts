/**
 * Request provider for memory (H3, #53–#55): puts saved memories and the
 * recent-chat digest into the prompt, offers the memory tools, and records
 * which memories each answer had in front of it.
 *
 * Cache contract (docs/antichat/m7-prompt-eval.md §2): both blocks are
 * `session` blocks at the end of the system message, after every stable
 * block, and they are **frozen per chat**: built on the chat's first
 * request and reused byte for byte, so the cached prefix survives every
 * turn. A new memory saved elsewhere reaches a chat on its next first
 * request; a deleted or edited memory, or memory being switched off, breaks
 * the freeze at once (privacy before cache). Memories found for the current
 * message ride on the newest user message as turn context.
 */
import type {
  Contribution,
  RequestContext,
  RequestProvider,
  SystemBlock,
  ToolDefinition,
} from '../prompt/types';
import type {ChatResolver} from './chatScope';
import {hasMemoryCue} from './extraction';
import {DigestStore, renderRecentChats} from './digest';
import type {Embedder, EmbedderProvider} from './embeddings/types';
import type {VectorStore} from './embeddings/vectorStore';
import type {MemoryStore} from './MemoryStore';
import {
  memoryBudgetFor,
  renderMemoryBlock,
  renderRetrievedLine,
  retrieveMemories,
  selectAlways,
  type MemoryBudget,
} from './retrieval';
import {
  FORGET_MEMORY_DEFINITION,
  SAVE_MEMORY_DEFINITION,
  SEARCH_CHATS_DEFINITION,
} from './tools';
import type {MemoryItem, MemoryRequestMeta} from './types';

export const MEMORY_PROVIDER_ID = 'antichat.memory';
export const MEMORY_BLOCK_ID = 'memory';
export const RECENT_CHATS_BLOCK_ID = 'recent-chats';

export interface MemoryProviderOptions {
  store: MemoryStore;
  resolveChat: ChatResolver;
  digests?: DigestStore;
  embedder?: EmbedderProvider;
  vectors?: VectorStore;
  /** Override the per-context budget (tests, experiments). */
  budget?: (nCtx: number) => MemoryBudget;
  /** Offer `save_memory` / `forget_memory` (default true). */
  writeTools?: boolean;
  /** Add the one-line reminder to use them (default true; see m9-eval.md). */
  toolHint?: boolean;
}

/**
 * Without this line Gemma 4 E2B answers "I have noted that" and calls
 * nothing (docs/antichat/m9-eval.md §3).
 */
export const MEMORY_TOOL_HINT =
  'When the user asks you to remember or to forget something about them, call save_memory or forget_memory first, then answer.';
export const MEMORY_TOOL_HINT_BLOCK_ID = 'memory-tools';

/**
 * Without the tools a model still answers "I'll remember that" in a
 * temporary chat (both test models did). The note makes it say the truth.
 */
export const TEMPORARY_CHAT_NOTE =
  'This is a temporary chat: nothing from it is saved or remembered later. If the user asks you to remember something, tell them that temporary chats do not save memories.';

export const TEMPORARY_CHAT_REMINDER =
  'Temporary chat: this will not be remembered after the chat ends. Say so instead of promising to remember.';

export const MEMORY_PAUSED_REMINDER =
  'Memory is paused in Settings: nothing new is saved. Say so instead of promising to remember.';
export const OFFLINE_CHAT_MEMORY_REMINDER =
  'Offline chat: memory is read-only here, nothing new is saved. Say so instead of promising to remember.';

const temporaryNote: SystemBlock = {
  id: 'memory-temporary',
  slot: 'stable',
  order: 85,
  text: TEMPORARY_CHAT_NOTE,
};

interface Frozen {
  key: string;
  firstUserText: string;
  revision: number;
  day: string;
  always: MemoryItem[];
  alwaysText: string;
  alwaysTokens: number;
  recentText: string;
  recentCount: number;
}

const PENDING = '\u0000pending';

const firstUserText = (context: RequestContext): string => {
  const first = context.messages.find(message => message.role === 'user');
  if (!first) {
    return '';
  }
  return typeof first.content === 'string'
    ? first.content
    : JSON.stringify(first.content ?? '');
};

export function createMemoryProvider(
  options: MemoryProviderOptions,
): RequestProvider {
  const {store} = options;
  // One frozen snapshot is enough: the KV cache only survives between
  // consecutive requests of the same chat.
  let frozen: Frozen | null = null;

  const contribute = async (
    context: RequestContext,
  ): Promise<Contribution | void> => {
    const settings = store.getSettings();
    if (!settings.enabled) {
      frozen = null;
      return;
    }
    const {session, runtime} = context;
    const chat = await options.resolveChat(session.id);
    const temporary = !!session.temporary || chat.temporary;
    // Said again next to the request itself: the note in the system
    // message alone did not stop Gemma 4 E2B from answering "noted".
    const temporaryReminder =
      temporary && hasMemoryCue(context.userText)
        ? [TEMPORARY_CHAT_REMINDER]
        : [];
    // Paused or an offline chat: memories are read, never written.
    const readOnly = settings.paused || !!session.offline || !!chat.readOnly;
    if (!temporary && readOnly && hasMemoryCue(context.userText)) {
      temporaryReminder.push(
        settings.paused ? MEMORY_PAUSED_REMINDER : OFFLINE_CHAT_MEMORY_REMINDER,
      );
    }
    if (temporary && !settings.personalizeTemporary) {
      return {systemBlocks: [temporaryNote], turnContext: temporaryReminder};
    }
    const budget = (options.budget ?? memoryBudgetFor)(runtime.nCtx);
    const counter = runtime.tokenCounter;
    const now = runtime.now.getTime();
    const day = runtime.now.toDateString();
    const first = firstUserText(context);
    const key = session.id ?? PENDING;

    // A chat gets its row after the first send: adopt the pending snapshot.
    if (
      frozen &&
      frozen.key === PENDING &&
      key !== PENDING &&
      frozen.firstUserText === first
    ) {
      frozen = {...frozen, key};
    }
    const reusable =
      frozen &&
      frozen.key === key &&
      frozen.firstUserText === first &&
      frozen.revision === store.revision &&
      frozen.day === day;

    if (!reusable) {
      const visible = await store.visible(chat.scope);
      const picked = await selectAlways(
        visible,
        budget.alwaysTokens,
        counter,
        now,
      );
      let recentText = '';
      let recentCount = 0;
      if (
        options.digests &&
        settings.referenceChats &&
        budget.digestChats > 0
      ) {
        const recent = await options.digests.recent({
          limit: budget.digestChats,
          excludeSessionId: session.id ?? null,
          onlyProjectId:
            chat.scope.projectId && chat.scope.projectOnly
              ? chat.scope.projectId
              : null,
          isolatedProjectIds: chat.isolatedProjectIds,
        });
        const rendered = await renderRecentChats(
          recent,
          budget.digestTokens,
          counter,
          budget.searchChats,
        );
        recentText = rendered.text;
        recentCount = rendered.count;
      }
      frozen = {
        key,
        firstUserText: first,
        revision: store.revision,
        day,
        always: picked.selected,
        alwaysText: renderMemoryBlock(picked.selected),
        alwaysTokens: picked.tokens,
        recentText,
        recentCount,
      };
    }
    const snapshot = frozen!;

    // Memories that did not fit the block, looked up for this message.
    let embedder: Embedder | null = null;
    if (options.embedder && options.vectors) {
      try {
        embedder = await options.embedder();
      } catch {
        embedder = null;
      }
    }
    const retrieved = await retrieveMemories(store, context.userText, {
      scope: chat.scope,
      exclude: new Set(snapshot.always.map(item => item.id)),
      limit: budget.maxRetrieved,
      tokens: budget.retrievedTokens,
      counter,
      embedder,
      vectors: options.vectors,
    });
    const retrievedLine = renderRetrievedLine(retrieved);

    const systemBlocks: SystemBlock[] = temporary ? [temporaryNote] : [];
    if (snapshot.alwaysText) {
      systemBlocks.push({
        id: MEMORY_BLOCK_ID,
        slot: 'session',
        order: 50,
        text: snapshot.alwaysText,
      });
    }
    if (snapshot.recentText) {
      systemBlocks.push({
        id: RECENT_CHATS_BLOCK_ID,
        slot: 'session',
        order: 60,
        text: snapshot.recentText,
      });
    }

    // The tool set depends on settings and the chat only, never on the
    // message, so it stays fixed for the life of a chat (Qwen3.5 renders
    // tools before the system text).
    const tools: ToolDefinition[] = [];
    if (!temporary && !readOnly && options.writeTools !== false) {
      tools.push(SAVE_MEMORY_DEFINITION, FORGET_MEMORY_DEFINITION);
      if (options.toolHint !== false) {
        // Stable: it depends on the settings and the kind of chat only.
        systemBlocks.push({
          id: MEMORY_TOOL_HINT_BLOCK_ID,
          slot: 'stable',
          order: 85,
          text: MEMORY_TOOL_HINT,
        });
      }
    }
    if (settings.referenceChats && budget.searchChats) {
      tools.push(SEARCH_CHATS_DEFINITION);
    }

    const injected: MemoryRequestMeta['injected'] = [
      ...snapshot.always.map(item => ({
        id: item.id,
        text: item.text,
        kind: item.kind,
        how: 'always' as const,
      })),
      ...retrieved.map(item => ({
        id: item.id,
        text: item.text,
        kind: item.kind,
        how: 'retrieved' as const,
      })),
    ];
    const meta: MemoryRequestMeta = {
      injected,
      tokens:
        snapshot.alwaysTokens +
        (retrievedLine ? await counter.countText(retrievedLine) : 0),
      recentChats: snapshot.recentCount,
      paused: settings.paused,
    };
    // Temporary chats leave no trace on disk, not even a use record.
    if (!temporary && session.id && injected.length > 0) {
      meta.useId =
        (await store.recordUse(
          session.id,
          injected.map(item => ({memoryId: item.id, how: item.how})),
        )) ?? undefined;
    }
    return {
      systemBlocks,
      turnContext: [
        ...(retrievedLine ? [retrievedLine] : []),
        ...temporaryReminder,
      ],
      tools,
      meta: {memory: meta},
    };
  };

  return {id: MEMORY_PROVIDER_ID, order: 50, contribute};
}
