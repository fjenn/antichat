import type {NodePayload, NodeRecord, Role, SessionMeta} from './types';

/**
 * ChatGPT's data-export format (`conversations.json`): an array of
 * conversations, each a `mapping` of nodes with `parent` / `children` and a
 * `current_node`; the visible thread is the path from `current_node` up to
 * the root.
 *
 * Import keeps the messages a person sees (user and assistant text) as tree
 * nodes and tucks everything else (root, system, tool, reasoning nodes) into
 * `ext`, so a conversation that was imported and not changed exports back
 * to the same JSON.
 */

export interface RawEntry {
  id: string;
  message: Record<string, any> | null;
  parent: string | null;
  children: string[];
}

export interface ParsedNode {
  extId: string;
  parentExtId: string | null;
  role: Role;
  text: string;
  /** Reasoning text gathered from hidden `thoughts` nodes above this one. */
  reasoning: string;
  createdAt: number;
  depth: number;
  onPath: boolean;
  /** The original message and child order, for a faithful re-export. */
  raw: {message: Record<string, any>; children: string[]};
  /** Hidden entries between the visible parent and this node, top down. */
  hidden: RawEntry[];
}

export interface ParsedConversation {
  extId: string;
  title: string;
  createdAt: number;
  updatedAt: number;
  archived: boolean;
  /** The conversation object without its `mapping`. */
  conv: Record<string, any>;
  /** Visible nodes, parents before children. */
  nodes: ParsedNode[];
  /** Deepest visible node on the current path. */
  currentExtId: string | null;
  /** Hidden entries no visible node sits below. */
  orphans: RawEntry[];
}

export const SYNTHETIC_ROOT_ID = 'client-created-root';

function toMs(seconds: unknown): number | null {
  return typeof seconds === 'number' && isFinite(seconds) && seconds > 0
    ? Math.round(seconds * 1000)
    : null;
}

function partsText(parts: unknown): string {
  if (!Array.isArray(parts)) {
    return '';
  }
  return parts
    .map(part => {
      if (typeof part === 'string') {
        return part;
      }
      if (part && typeof part === 'object' && typeof part.text === 'string') {
        // Voice transcripts and similar typed parts.
        return part.text;
      }
      return '';
    })
    .filter(part => part.length > 0)
    .join('\n');
}

/** The text a person sees for this message, or '' when it is not shown. */
export function visibleText(message: Record<string, any> | null): string {
  if (!message) {
    return '';
  }
  const role = message.author?.role;
  if (role !== 'user' && role !== 'assistant') {
    return '';
  }
  if (message.metadata?.is_visually_hidden_from_conversation) {
    return '';
  }
  if (
    role === 'assistant' &&
    message.recipient &&
    message.recipient !== 'all'
  ) {
    return ''; // a tool call
  }
  const content = message.content ?? {};
  switch (content.content_type) {
    case 'text':
    case 'multimodal_text':
      return partsText(content.parts).trim();
    default:
      return '';
  }
}

function thoughtsText(message: Record<string, any> | null): string {
  const content = message?.content;
  if (
    content?.content_type !== 'thoughts' ||
    !Array.isArray(content.thoughts)
  ) {
    return '';
  }
  return content.thoughts
    .map((thought: any) =>
      [thought?.summary, thought?.content]
        .filter(part => typeof part === 'string' && part.length > 0)
        .join('\n'),
    )
    .filter((text: string) => text.length > 0)
    .join('\n\n');
}

/**
 * Reads one conversation, tolerating missing fields, missing `children`
 * arrays and dangling ids. Returns null when it is not a conversation.
 */
export function parseChatGptConversation(raw: any): ParsedConversation | null {
  if (!raw || typeof raw !== 'object' || typeof raw.mapping !== 'object') {
    return null;
  }
  const mapping: Record<string, any> = raw.mapping ?? {};
  const entries = new Map<string, RawEntry>();
  for (const [key, value] of Object.entries(mapping)) {
    if (!value || typeof value !== 'object') {
      continue;
    }
    const id = typeof value.id === 'string' ? value.id : key;
    entries.set(id, {
      id,
      message:
        value.message && typeof value.message === 'object'
          ? value.message
          : null,
      parent:
        typeof value.parent === 'string' && value.parent in mapping
          ? value.parent
          : null,
      children: Array.isArray(value.children)
        ? value.children.filter((child: unknown) => typeof child === 'string')
        : [],
    });
  }
  // Children known only through a `parent` pointer are appended.
  for (const entry of entries.values()) {
    entry.children = entry.children.filter(child => entries.has(child));
  }
  for (const entry of entries.values()) {
    const parent = entry.parent ? entries.get(entry.parent) : undefined;
    if (parent && !parent.children.includes(entry.id)) {
      parent.children.push(entry.id);
    }
  }

  const convCreated = toMs(raw.create_time) ?? Date.now();
  const convUpdated = toMs(raw.update_time) ?? convCreated;

  // The current path, from the leaf up.
  const onCurrentPath = new Set<string>();
  let cursor: string | null =
    typeof raw.current_node === 'string' && entries.has(raw.current_node)
      ? raw.current_node
      : null;
  if (!cursor) {
    // No usable current_node: follow the last child from a root.
    const root = [...entries.values()].find(entry => !entry.parent);
    cursor = root?.id ?? null;
    while (cursor) {
      const children: string[] = entries.get(cursor)!.children;
      if (children.length === 0) {
        break;
      }
      cursor = children[children.length - 1];
    }
  }
  for (let hop = 0; cursor && hop <= entries.size; hop++) {
    onCurrentPath.add(cursor);
    cursor = entries.get(cursor)!.parent;
  }

  const nodes: ParsedNode[] = [];
  const claimed = new Set<string>();
  const visited = new Set<string>();
  let currentExtId: string | null = null;
  let lastTime = convCreated - 1;

  interface Frame {
    id: string;
    visibleParent: ParsedNode | null;
    hidden: RawEntry[];
  }
  const stack: Frame[] = [...entries.values()]
    .filter(entry => !entry.parent)
    .reverse()
    .map(entry => ({id: entry.id, visibleParent: null, hidden: []}));

  while (stack.length > 0) {
    const frame = stack.pop()!;
    if (visited.has(frame.id)) {
      continue; // a cycle or a node listed under two parents
    }
    visited.add(frame.id);
    const entry = entries.get(frame.id)!;
    const text = visibleText(entry.message);
    let visibleParent = frame.visibleParent;
    let hidden = frame.hidden;
    if (text.length > 0 && entry.message) {
      const stamp = toMs(entry.message.create_time);
      const createdAt = stamp ?? lastTime + 1;
      lastTime = Math.max(lastTime, createdAt);
      const node: ParsedNode = {
        extId: entry.id,
        parentExtId: visibleParent?.extId ?? null,
        role: entry.message.author.role,
        text,
        reasoning: hidden
          .map(item => thoughtsText(item.message))
          .filter(part => part.length > 0)
          .join('\n\n'),
        createdAt,
        depth: visibleParent ? visibleParent.depth + 1 : 0,
        onPath: onCurrentPath.has(entry.id),
        raw: {message: entry.message, children: entry.children},
        hidden,
      };
      for (const item of hidden) {
        claimed.add(item.id);
      }
      nodes.push(node);
      if (node.onPath) {
        currentExtId = node.extId; // parents come first, so the last wins
      }
      visibleParent = node;
      hidden = [];
    } else {
      hidden = [...hidden, entry];
    }
    for (let i = entry.children.length - 1; i >= 0; i--) {
      stack.push({id: entry.children[i], visibleParent, hidden});
    }
  }

  const visibleIds = new Set(nodes.map(node => node.extId));
  const orphans = [...entries.values()].filter(
    entry => !visibleIds.has(entry.id) && !claimed.has(entry.id),
  );

  const conv: Record<string, any> = {...raw};
  delete conv.mapping;
  const extId =
    typeof raw.conversation_id === 'string'
      ? raw.conversation_id
      : typeof raw.id === 'string'
        ? raw.id
        : '';
  return {
    extId,
    title:
      typeof raw.title === 'string' && raw.title.length > 0
        ? raw.title
        : 'Untitled',
    createdAt: convCreated,
    updatedAt: convUpdated,
    archived: raw.is_archived === true,
    conv,
    nodes,
    currentExtId,
    orphans,
  };
}

/** The upstream message row an imported node becomes. */
export function importedPayload(
  node: ParsedNode,
  authors: {user: string; assistant: string},
): NodePayload {
  // A conversation exported by AntiChat carries the original row.
  const own = node.raw.message.metadata?.antichat?.payload;
  if (own && typeof own === 'object' && typeof own.type === 'string') {
    return own as NodePayload;
  }
  if (node.role === 'user') {
    return {author: authors.user, type: 'text', text: node.text, metadata: {}};
  }
  const step: Record<string, string> = {content: node.text};
  if (node.reasoning.length > 0) {
    step.reasoningContent = node.reasoning;
  }
  const model = node.raw.message.metadata?.model_slug;
  return {
    author: authors.assistant,
    type: 'assistant_turn',
    metadata: {
      steps: [step],
      copyable: true,
      ...(typeof model === 'string' ? {importedModel: model} : {}),
    },
  };
}

function nativeMessage(node: NodeRecord): Record<string, any> {
  const images: unknown[] = Array.isArray(node.payload.metadata?.imageUris)
    ? node.payload.metadata.imageUris
    : [];
  return {
    id: node.extId ?? node.id,
    author: {role: node.role, name: null, metadata: {}},
    create_time: node.createdAt / 1000,
    update_time: null,
    content:
      images.length > 0
        ? {
            content_type: 'multimodal_text',
            parts: [
              ...images.map(uri => ({
                content_type: 'image_asset_pointer',
                asset_pointer: String(uri),
              })),
              node.text,
            ],
          }
        : {content_type: 'text', parts: [node.text]},
    status: 'finished_successfully',
    end_turn: node.role === 'assistant' ? true : null,
    weight: 1.0,
    metadata: {antichat: {payload: node.payload}},
    recipient: 'all',
    channel: null,
  };
}

function sameIds(a: string[], b: string[]): boolean {
  return a.length === b.length && a.every(id => b.includes(id));
}

/**
 * Builds one conversation of `conversations.json` from a chat's meta row
 * and all of its nodes (visible and parked), given in creation order.
 */
export function exportChatGptConversation(
  meta: SessionMeta,
  nodes: NodeRecord[],
): Record<string, any> {
  const imported = meta.ext?.chatgpt as
    | {
        conv: Record<string, any>;
        orphans: RawEntry[];
        currentExtId: string | null;
        updatedAt: number;
        title: string;
      }
    | undefined;

  const byId = new Map(nodes.map(node => [node.id, node]));
  const exportId = (node: NodeRecord) => node.extId ?? node.id;
  const hiddenOf = (node: NodeRecord): RawEntry[] =>
    node.ext?.chatgpt?.hidden ?? [];

  interface Out {
    id: string;
    message: Record<string, any> | null;
    parent: string | null;
    children: string[];
    order: string[];
  }
  const out = new Map<string, Out>();
  const addHidden = (entry: RawEntry) => {
    if (!out.has(entry.id)) {
      out.set(entry.id, {
        id: entry.id,
        message: entry.message,
        parent: entry.parent,
        children: [],
        order: entry.children ?? [],
      });
    }
  };

  // Where a first message with no hidden ancestors of its own hangs: under
  // the same hidden node as its sibling versions, else a synthetic root.
  let rootParent: string | null = null;
  for (const node of nodes) {
    const hidden = hiddenOf(node);
    if (node.parentId === null && hidden.length > 0) {
      rootParent = hidden[hidden.length - 1].id;
      break;
    }
  }
  if (!rootParent) {
    const orphanRoot = imported?.orphans.find(entry => entry.parent === null);
    rootParent = orphanRoot?.id ?? SYNTHETIC_ROOT_ID;
  }

  for (const entry of imported?.orphans ?? []) {
    addHidden(entry);
  }
  for (const node of nodes) {
    const hidden = hiddenOf(node);
    for (const entry of hidden) {
      addHidden(entry);
    }
    const parentNode = node.parentId ? byId.get(node.parentId) : undefined;
    const parent =
      hidden.length > 0
        ? hidden[hidden.length - 1].id
        : parentNode
          ? exportId(parentNode)
          : rootParent;
    out.set(exportId(node), {
      id: exportId(node),
      message: node.ext?.chatgpt?.message ?? nativeMessage(node),
      parent,
      children: [],
      order: node.ext?.chatgpt?.children ?? [],
    });
  }
  if (!out.has(rootParent)) {
    out.set(rootParent, {
      id: rootParent,
      message: null,
      parent: null,
      children: [],
      order: [],
    });
  }
  for (const entry of out.values()) {
    if (entry.parent && out.has(entry.parent)) {
      out.get(entry.parent)!.children.push(entry.id);
    }
  }

  const mapping: Record<string, any> = {};
  for (const entry of out.values()) {
    // Original child order where it is known; new children go last.
    const children = sameIds(entry.children, entry.order)
      ? entry.order
      : [...entry.children].sort((a, b) => {
          const ia = entry.order.indexOf(a);
          const ib = entry.order.indexOf(b);
          return (
            (ia < 0 ? Number.MAX_SAFE_INTEGER : ia) -
            (ib < 0 ? Number.MAX_SAFE_INTEGER : ib)
          );
        });
    mapping[entry.id] = {
      id: entry.id,
      message: entry.message,
      parent: entry.parent,
      children,
    };
  }

  const leaf = meta.currentLeafId ? byId.get(meta.currentLeafId) : undefined;
  const leafId = leaf ? exportId(leaf) : rootParent;
  const antichat = {
    version: 1,
    pinned: meta.pinnedAt !== null,
    locked: meta.locked,
    projectId: meta.projectId,
    originKind: meta.originKind,
    originSessionId: meta.originSessionId,
  };

  if (imported) {
    const untouchedLeaf = leafId === imported.currentExtId;
    const result: Record<string, any> = {
      ...imported.conv,
      mapping,
    };
    if (meta.title !== imported.title || !('title' in imported.conv)) {
      result.title = meta.title;
    }
    if (!untouchedLeaf || !('current_node' in imported.conv)) {
      result.current_node = leafId;
    }
    if (meta.updatedAt !== imported.updatedAt) {
      result.update_time = meta.updatedAt / 1000;
    }
    if ('is_archived' in imported.conv || meta.archivedAt !== null) {
      result.is_archived = meta.archivedAt !== null;
    }
    return result;
  }

  return {
    title: meta.title,
    create_time: meta.createdAt / 1000,
    update_time: meta.updatedAt / 1000,
    mapping,
    moderation_results: [],
    current_node: leafId,
    plugin_ids: null,
    conversation_id: meta.sessionId,
    conversation_template_id: null,
    gizmo_id: null,
    gizmo_type: null,
    is_archived: meta.archivedAt !== null,
    is_starred: null,
    safe_urls: [],
    blocked_urls: [],
    default_model_slug: null,
    conversation_origin: null,
    voice: null,
    async_status: null,
    disabled_tool_ids: [],
    is_do_not_remember: false,
    memory_scope: 'global_enabled',
    id: meta.sessionId,
    antichat,
  };
}
