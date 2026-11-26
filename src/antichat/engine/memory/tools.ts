/**
 * The memory tools the chat model can call:
 *  - `save_memory` / `forget_memory` for explicit requests ("remember
 *    that…", "forget that…");
 *  - `search_chats` to look something up in earlier conversations.
 *
 * They are upstream `TalentEngine`s, so the agent runner executes them like
 * any other tool; the request provider offers their definitions.
 *
 * A tool runs while the chat model is generating, so it never calls the
 * model itself: an unclear duplicate is saved and left for the idle pass.
 */
import type {
  TalentEngine,
  TalentResult,
  ToolDefinition,
} from '../../../services/talents/types';
import {
  formatChatSearch,
  searchChats,
  type ChatSearchOptions,
} from './chatSearch';
import {detectSensitive, screenFacts} from './extraction';
import type {MemoryStore} from './MemoryStore';
import {coverage, normalizeFact, stemSet} from './text';
import type {MemoryItem, MemoryScope} from './types';
import {inferKind, type MemoryWriter} from './writer';

export const SAVE_MEMORY = 'save_memory';
export const FORGET_MEMORY = 'forget_memory';
export const SEARCH_CHATS = 'search_chats';

/** What a tool needs to know about the chat it is called from. */
export interface ToolChatContext {
  sessionId?: string | null;
  temporary?: boolean;
  /** Offline chat: memory is read-only. */
  readOnly?: boolean;
  scope?: MemoryScope;
  /** Projects whose chats `search_chats` must not show elsewhere. */
  isolatedProjectIds?: string[];
  /** Characters a tool result may take (smaller on a 4k context). */
  resultChars?: number;
  /**
   * The user's message being answered. With it, `save_memory` applies the
   * same screen as the background pass: a private detail is saved only
   * when the user asked for it.
   */
  userText?: string;
}

export type ToolContextResolver = () =>
  | Promise<ToolChatContext>
  | ToolChatContext;

export const SAVE_MEMORY_DEFINITION: ToolDefinition = {
  type: 'function',
  function: {
    name: SAVE_MEMORY,
    description:
      'Save a lasting fact about the user so it is known in future chats. Call it when the user asks you to remember something, or states a lasting fact about themselves (name, home, job, family, diet, preferences, how they want answers). Not for one-off requests. Never say you saved or will remember something unless you called this tool.',
    parameters: {
      type: 'object',
      properties: {
        fact: {
          type: 'string',
          description:
            'The fact as one short sentence starting with "User", for example "User is vegetarian."',
        },
      },
      required: ['fact'],
    },
  },
};

export const FORGET_MEMORY_DEFINITION: ToolDefinition = {
  type: 'function',
  function: {
    name: FORGET_MEMORY,
    description:
      'Delete a saved memory about the user. Call it when the user asks you to forget something or says a saved fact is no longer true.',
    parameters: {
      type: 'object',
      properties: {
        fact: {
          type: 'string',
          description:
            'What to forget, in a few words, for example "is vegetarian".',
        },
      },
      required: ['fact'],
    },
  },
};

export const SEARCH_CHATS_DEFINITION: ToolDefinition = {
  type: 'function',
  function: {
    name: SEARCH_CHATS,
    description:
      'Search the user\'s earlier chats. Call it when the user refers to something you discussed before that is not in this chat ("what was that recipe you gave me", "as we discussed last week").',
    parameters: {
      type: 'object',
      properties: {
        query: {
          type: 'string',
          description: 'Two to five keywords, for example "lisbon trip hotel".',
        },
      },
      required: ['query'],
    },
  },
};

const text = (summary: string): TalentResult => ({type: 'text', summary});

/**
 * Gemma 4 E2B writes nothing at all after a bare "Saved." result; with
 * this line it confirms and goes on to the rest of the message.
 */
const CONFIRM =
  '\nTell the user in one short sentence that you will remember it, then answer anything else they asked.';

const firstString = (args: Record<string, any>, keys: string[]): string => {
  for (const key of keys) {
    if (typeof args?.[key] === 'string' && args[key].trim()) {
      return args[key].trim();
    }
  }
  return '';
};

/**
 * Memories that `query` most plausibly means: full-text hits whose words
 * the query covers well. Returned best first.
 */
export async function matchForForget(
  store: MemoryStore,
  query: string,
  scope: MemoryScope = {},
): Promise<MemoryItem[]> {
  const wanted = stemSet(normalizeFact(query));
  if (wanted.size === 0) {
    return [];
  }
  const hits = await store.searchText(query, scope, 8);
  return hits
    .map(hit => {
      const stems = stemSet(normalizeFact(hit.item.text));
      return {
        item: hit.item,
        // Either the query names the memory, or the memory names the query.
        score: Math.max(coverage(wanted, stems), coverage(stems, wanted)),
      };
    })
    .filter(entry => entry.score >= 0.5)
    .sort((a, b) => b.score - a.score)
    .slice(0, 3)
    .map(entry => entry.item);
}

export interface MemoryToolsOptions {
  store: MemoryStore;
  writer: MemoryWriter;
  context: ToolContextResolver;
}

export function createSaveMemoryTool(
  options: MemoryToolsOptions,
): TalentEngine {
  return {
    name: SAVE_MEMORY,
    toToolDefinition: () => SAVE_MEMORY_DEFINITION,
    async execute(args) {
      const fact = firstString(args, ['fact', 'text', 'memory', 'content']);
      if (!fact) {
        return text('Nothing was saved: the fact was empty.');
      }
      const chat = await options.context();
      if (chat.temporary) {
        return text(
          'Not saved: this is a temporary chat, which never writes memories. Tell the user.',
        );
      }
      if (chat.readOnly) {
        return text(
          'Not saved: this is an offline chat, where memory is read-only. Tell the user.',
        );
      }
      const settings = options.store.getSettings();
      if (!settings.enabled || settings.paused) {
        return text(
          'Not saved: memory is switched off or paused in Settings. Tell the user.',
        );
      }
      // The model decides to call; code decides what may be kept.
      let explicit = true;
      let sensitive = detectSensitive(fact);
      if (chat.userText) {
        const [kept] = screenFacts(
          [{text: fact, kind: inferKind(fact), sensitive, explicit: false}],
          {turns: [chat.userText], includeSensitive: settings.includeSensitive},
        );
        if (!kept) {
          return text(
            sensitive
              ? 'Not saved: this is a private detail and the user did not ask to remember it. Do not say it was saved.'
              : 'Not saved: this is not a lasting fact about the user. Do not say it was saved.',
          );
        }
        explicit = kept.explicit;
        sensitive = kept.sensitive;
      }
      const result = await options.writer.save({
        text: fact,
        origin: 'tool',
        explicit,
        sensitive,
        scope: chat.scope,
        sessionId: chat.sessionId ?? null,
      });
      switch (result.status) {
        case 'added':
          return text(`Saved to memory: ${result.memory!.text}${CONFIRM}`);
        case 'updated':
          return text(`Memory updated: ${result.memory!.text}${CONFIRM}`);
        case 'duplicate':
          return text(
            'This is already in memory; nothing to save. Do not mention memory, just answer what the user asked.',
          );
        case 'paused':
          return text('Not saved: memory is switched off or paused.');
        case 'blocked':
          return text(
            'Not saved: the user deleted this memory before. Save it only if they ask again.',
          );
        default:
          return text('Nothing was saved.');
      }
    },
  };
}

export function createForgetMemoryTool(
  options: MemoryToolsOptions,
): TalentEngine {
  return {
    name: FORGET_MEMORY,
    toToolDefinition: () => FORGET_MEMORY_DEFINITION,
    async execute(args) {
      const query = firstString(args, ['fact', 'query', 'text', 'memory']);
      if (!query) {
        return text('Nothing was deleted: say what to forget.');
      }
      const chat = await options.context();
      if (chat.temporary) {
        return text('Not possible in a temporary chat.');
      }
      if (chat.readOnly) {
        return text('Not possible in an offline chat: memory is read-only.');
      }
      const matches = await matchForForget(options.store, query, chat.scope);
      if (matches.length === 0) {
        return text('No saved memory matches that. Nothing was deleted.');
      }
      await options.store.delete(
        matches.map(item => item.id),
        'tool',
      );
      return text(
        `Deleted from memory: ${matches.map(item => item.text).join(' | ')}\nTell the user in one short sentence that you have forgotten it.`,
      );
    },
  };
}

export interface SearchChatsToolOptions {
  db: MemoryStore['db'];
  store: MemoryStore;
  context: ToolContextResolver;
}

export function createSearchChatsTool(
  options: SearchChatsToolOptions,
): TalentEngine {
  return {
    name: SEARCH_CHATS,
    toToolDefinition: () => SEARCH_CHATS_DEFINITION,
    async execute(args) {
      const query = firstString(args, ['query', 'q', 'keywords', 'text']);
      if (!query) {
        return text('No query given.');
      }
      const settings = options.store.getSettings();
      if (!settings.enabled || !settings.referenceChats) {
        return text('Chat history reference is switched off in Settings.');
      }
      const chat = await options.context();
      const search: ChatSearchOptions = {
        excludeSessionId: chat.sessionId ?? null,
        onlyProjectId:
          chat.scope?.projectId && chat.scope.projectOnly
            ? chat.scope.projectId
            : null,
        isolatedProjectIds: chat.isolatedProjectIds,
      };
      const results = await searchChats(options.db, query, search);
      return text(formatChatSearch(results, chat.resultChars ?? 900));
    },
  };
}
