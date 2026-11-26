/**
 * Shapes of the memory engine (M9). The UI half builds on `MemoryItem`,
 * `MemorySettings`, `MemoryUse` and the events; nothing here needs a model.
 */

/**
 * - `profile`: who the user is (name, home, job, family, diet). Always sent.
 * - `preference`: how the user wants answers. Always sent.
 * - `context`: what is going on (projects, plans, interests). Sent when
 *   there is room, otherwise retrieved for a matching message; ages faster.
 */
export type MemoryKind = 'profile' | 'preference' | 'context';

/**
 * Who wrote the memory.
 * - `tool`: the model called `save_memory` because the user asked.
 * - `extraction`: the idle pass found it in a finished chat.
 * - `user`: typed or edited in the manage screen.
 */
export type MemoryOrigin = 'tool' | 'extraction' | 'user';

export type SensitiveCategory =
  | 'health'
  | 'sexuality'
  | 'religion'
  | 'politics'
  | 'finances'
  | 'identity'
  /** Flagged private by the model without a category. */
  | 'other';

export interface MemoryItem {
  id: string;
  text: string;
  kind: MemoryKind;
  origin: MemoryOrigin;
  /** Null: a global memory. Set: visible only inside that project. */
  projectId: string | null;
  pinned: boolean;
  /** 0–1. Explicit requests and profile facts rank above passing context. */
  importance: number;
  sensitive: SensitiveCategory | null;
  sourceSessionId: string | null;
  sourceNodeId: string | null;
  createdAt: number;
  updatedAt: number;
  lastUsedAt: number | null;
  useCount: number;
  /** Text before the last update, so the UI can offer "Undo". */
  previousText: string | null;
}

export interface MemorySettings {
  /** Master switch ("Reference saved memories"). Off: nothing read or written. */
  enabled: boolean;
  /** "Pause": memories are still used, nothing new is saved. */
  paused: boolean;
  /** Background extraction from finished chats (the tool works either way). */
  autoExtract: boolean;
  /** "Reference chat history": recent-chat digest and `search_chats`. */
  referenceChats: boolean;
  /** Keep facts about health, sexuality, religion, politics, money that the
   *  user did not ask to save. Off by default. */
  includeSensitive: boolean;
  /** Temporary chats read memories ("Personalized"); they never write. */
  personalizeTemporary: boolean;
  /** Hard cap on stored memories; the least valuable is evicted above it. */
  maxItems: number;
}

export const DEFAULT_MEMORY_SETTINGS: MemorySettings = {
  enabled: true,
  paused: false,
  autoExtract: true,
  referenceChats: true,
  includeSensitive: false,
  personalizeTemporary: false,
  maxItems: 200,
};

/** Where a memory may be read or written. */
export interface MemoryScope {
  /** The chat's project, if it is in one. */
  projectId?: string | null;
  /** True when that project keeps its memory to itself. */
  projectOnly?: boolean;
}

export interface NewMemory {
  text: string;
  kind?: MemoryKind;
  origin: MemoryOrigin;
  projectId?: string | null;
  pinned?: boolean;
  importance?: number;
  sensitive?: SensitiveCategory | null;
  sourceSessionId?: string | null;
  sourceNodeId?: string | null;
}

export type MemoryEvent =
  /** A use record was tied to its answer (which memories it drew on). */
  | {type: 'used'; useId: string}
  | {type: 'saved'; memory: MemoryItem; sessionId?: string | null}
  | {
      type: 'updated';
      memory: MemoryItem;
      previousText: string;
      sessionId?: string | null;
    }
  | {
      type: 'deleted';
      ids: string[];
      reason: 'user' | 'tool' | 'evicted' | 'replaced';
    }
  | {type: 'cleared'}
  | {type: 'settings'; settings: MemorySettings};

/** How a memory reached the prompt. */
export type MemoryUseHow = 'always' | 'retrieved';

export interface MemoryUseItem {
  memoryId: string;
  text: string;
  kind: MemoryKind;
  how: MemoryUseHow;
  /** The reply (or the question) shares words with the memory. */
  cited: boolean;
}

/** One answer's memory sources: what the "memory used" chip opens. */
export interface MemoryUse {
  id: string;
  sessionId: string;
  /** Upstream id of the assistant message, once the reply is linked. */
  messageId: string | null;
  createdAt: number;
  items: MemoryUseItem[];
}

/** What the request provider leaves in `PreparedRequest.meta.memory`. */
export interface MemoryRequestMeta {
  /** Id of the stored use record; absent in temporary chats. */
  useId?: string;
  /** Every memory in this request's prompt. */
  injected: Array<{
    id: string;
    text: string;
    kind: MemoryKind;
    how: MemoryUseHow;
  }>;
  /** Tokens the memory block and the retrieved lines take. */
  tokens: number;
  /** Past chats listed in the digest block. */
  recentChats: number;
  paused: boolean;
}
