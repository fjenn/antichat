/**
 * Shapes shared by the conversation store, its port and its tests.
 */
export type Role = 'user' | 'assistant' | 'system' | 'tool';

/**
 * A row of upstream's WatermelonDB `messages` table, as plain data. The
 * store copies it verbatim into `nodes.payload`, so swapping a parked tail
 * back in restores exactly what upstream wrote.
 */
export interface UpMessage {
  id: string;
  /** Author id (upstream's fixed user / assistant ids). */
  author: string;
  /** 'text' | 'assistant_turn' | 'image' | 'file' | ... */
  type: string;
  text?: string;
  createdAt: number;
  /** Parsed `metadata` column (includes `steps`, `imageUris`, `authorData`). */
  metadata: Record<string, any>;
}

export interface UpSession {
  id: string;
  title: string;
  createdAt: number;
  pinned: boolean;
}

export type NodePayload = Omit<UpMessage, 'id' | 'createdAt'>;

export interface NodeRecord {
  seq: number;
  id: string;
  sessionId: string;
  parentId: string | null;
  role: Role;
  text: string;
  payload: NodePayload;
  extId: string | null;
  ext: Record<string, any> | null;
  createdAt: number;
  updatedAt: number;
  onPath: boolean;
  depth: number;
  activeChildId: string | null;
  /** Id of the upstream row that mirrors (or last mirrored) this node. */
  upId: string | null;
}

export type OriginKind = 'branch' | 'import';

export interface SessionMeta {
  sessionId: string;
  title: string;
  createdAt: number;
  updatedAt: number;
  archivedAt: number | null;
  pinnedAt: number | null;
  temporary: boolean;
  locked: boolean;
  projectId: string | null;
  currentLeafId: string | null;
  originKind: OriginKind | null;
  originSessionId: string | null;
  originNodeId: string | null;
  extId: string | null;
  ext: Record<string, any> | null;
}

/** One message of the visible thread plus its place among its versions. */
export interface ThreadMessage {
  nodeId: string;
  /** Upstream message id; what chat UI code holds. */
  messageId: string;
  role: Role;
  text: string;
  createdAt: number;
  /** 0-based position among the siblings (versions) of this message. */
  versionIndex: number;
  versionCount: number;
  /** Node ids of all versions, oldest first. */
  versionIds: string[];
}

export interface HistoryItem {
  sessionId: string;
  title: string;
  createdAt: number;
  updatedAt: number;
  pinned: boolean;
  archived: boolean;
  locked: boolean;
  projectId: string | null;
  originKind: OriginKind | null;
  originSessionId: string | null;
}

export type HistoryGroupKey =
  | 'today'
  | 'yesterday'
  | 'previous7Days'
  | 'previous30Days'
  | 'month'
  | 'year';

export interface HistoryGroup {
  key: HistoryGroupKey;
  /** Set for 'month' (0-11) and 'year' groups. */
  month?: number;
  year?: number;
  /** English fallback label; UI code localises from `key`. */
  label: string;
  items: HistoryItem[];
}

export interface HistoryListing {
  pinned: HistoryItem[];
  groups: HistoryGroup[];
}

export interface HistoryOptions {
  /** 'active' (default) hides archived chats; 'archived' lists only those. */
  scope?: 'active' | 'archived' | 'all';
  projectId?: string | null;
  now?: number;
}

/** A run of text; `match` runs are the search terms to highlight. */
export interface TextSegment {
  text: string;
  match: boolean;
}

export interface SearchSnippet {
  nodeId: string;
  /** Upstream message id when the hit is in the visible thread. */
  messageId: string | null;
  role: Role;
  onActivePath: boolean;
  segments: TextSegment[];
}

export interface SearchHit {
  sessionId: string;
  title: string;
  /** Title split into highlighted runs (one plain run when no title match). */
  titleSegments: TextSegment[];
  titleMatched: boolean;
  /** Best message hit in this chat, if any. */
  snippet: SearchSnippet | null;
  /** Number of matching messages in this chat. */
  messageMatches: number;
  /** Lower is better (bm25, title matches weighted up). */
  score: number;
  updatedAt: number;
  archived: boolean;
  locked: boolean;
}

export interface SearchOptions {
  limit?: number;
  includeArchived?: boolean;
  /** Locked chats are left out unless the caller has unlocked them. */
  includeLocked?: boolean;
  /** Also search parked versions (default: visible threads only). */
  includeParked?: boolean;
  projectId?: string;
  /** 'all' (default): every word must appear. 'any': one is enough. */
  match?: 'all' | 'any';
  /** Only messages of this side of the chat (default: both). */
  role?: 'user' | 'assistant';
}

export interface ImportResult {
  imported: string[];
  skipped: number;
  failed: number;
}

export interface ImportOptions {
  /** 'skip' (default) ignores conversations that were imported before. */
  duplicates?: 'skip' | 'copy';
}

export interface StoreStats {
  sessions: number;
  nodes: number;
  parkedNodes: number;
  temporarySessions: number;
}
