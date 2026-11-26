import {buildChatGptArchive, readChatGptArchive} from './archive';
import {
  exportChatGptConversation,
  importedPayload,
  parseChatGptConversation,
  ParsedConversation,
} from './chatgpt';
import type {ConversationStore} from './ConversationStore';
import {exportMarkdown, MarkdownOptions} from './markdown';
import type {ImportOptions, ImportResult, UpMessage} from './types';

/**
 * Export: every saved chat (or the given ones) in ChatGPT's
 * `conversations.json` shape, parked versions included. Temporary chats
 * have no nodes and are left out.
 */
export async function exportConversations(
  store: ConversationStore,
  sessionIds?: string[],
): Promise<Record<string, any>[]> {
  const rows = await store.db.all<{session_id: string}>(
    'SELECT session_id FROM session_meta WHERE temporary = 0 ORDER BY updated_at DESC, seq DESC',
  );
  const wanted = sessionIds ? new Set(sessionIds) : null;
  const conversations: Record<string, any>[] = [];
  for (const row of rows) {
    if (wanted && !wanted.has(row.session_id)) {
      continue;
    }
    const meta = await store.getMeta(row.session_id);
    if (!meta) {
      continue;
    }
    const nodes = await store.getAllNodes(row.session_id);
    conversations.push(exportChatGptConversation(meta, nodes));
  }
  return conversations;
}

export async function exportArchive(
  store: ConversationStore,
  sessionIds?: string[],
): Promise<Uint8Array> {
  return buildChatGptArchive(await exportConversations(store, sessionIds));
}

export async function exportSessionMarkdown(
  store: ConversationStore,
  sessionId: string,
  options?: MarkdownOptions,
): Promise<string> {
  await store.syncSession(sessionId);
  const meta = await store.getMeta(sessionId);
  if (!meta) {
    throw new Error(`Unknown chat ${sessionId}`);
  }
  return exportMarkdown(meta, await store.getPath(sessionId), options);
}

async function importOne(
  store: ConversationStore,
  parsed: ParsedConversation,
): Promise<string> {
  return store.write(async () => {
    const authors = store.upstream.authors;
    const ids = new Map<string, string>();
    for (const node of parsed.nodes) {
      ids.set(node.extId, store.newId());
    }
    const path = parsed.nodes.filter(node => node.onPath);
    const messages: UpMessage[] = path.map(node => ({
      ...importedPayload(node, authors),
      id: ids.get(node.extId)!,
      createdAt: node.createdAt,
    }));
    const own = parsed.conv.antichat ?? {};
    const sessionId = await store.upstream.createSession({
      title: parsed.title,
      createdAt: parsed.createdAt,
      pinned: own.pinned === true,
      messages,
    });
    const leaf = path[path.length - 1];
    await store.insertMeta({
      sessionId,
      title: parsed.title,
      createdAt: parsed.createdAt,
      updatedAt: parsed.updatedAt,
      archivedAt: parsed.archived ? parsed.updatedAt : null,
      pinnedAt: own.pinned === true ? store.now() : null,
      locked: own.locked === true,
      currentLeafId: leaf ? ids.get(leaf.extId)! : null,
      originKind: 'import',
      extId: parsed.extId || null,
      ext: {
        chatgpt: {
          conv: parsed.conv,
          orphans: parsed.orphans,
          currentExtId: parsed.currentExtId,
          updatedAt: parsed.updatedAt,
          title: parsed.title,
        },
      },
    });
    // The child each node last showed: the one on the current path, else
    // its newest (later rows overwrite earlier ones).
    const activeChild = new Map<string, string>();
    const settled = new Set<string>();
    for (const node of parsed.nodes) {
      if (!node.parentExtId || settled.has(node.parentExtId)) {
        continue;
      }
      activeChild.set(node.parentExtId, node.extId);
      if (node.onPath) {
        settled.add(node.parentExtId);
      }
    }
    for (const node of parsed.nodes) {
      const id = ids.get(node.extId)!;
      const child = activeChild.get(node.extId);
      await store.insertNode({
        id,
        sessionId,
        parentId: node.parentExtId ? ids.get(node.parentExtId)! : null,
        role: node.role,
        payload: importedPayload(node, authors),
        createdAt: node.createdAt,
        onPath: node.onPath,
        depth: node.depth,
        activeChildId: child ? ids.get(child)! : null,
        upId: node.onPath ? id : null,
        extId: node.extId,
        ext: {chatgpt: {...node.raw, hidden: node.hidden}},
      });
    }
    return sessionId;
  });
}

/**
 * Imports conversations in ChatGPT's export shape (also what
 * `exportConversations` writes). Each becomes a chat with its whole tree;
 * the visible thread is the conversation's current path.
 */
export async function importConversations(
  store: ConversationStore,
  conversations: unknown[],
  options: ImportOptions = {},
): Promise<ImportResult> {
  const result: ImportResult = {imported: [], skipped: 0, failed: 0};
  for (const raw of conversations) {
    let parsed: ParsedConversation | null = null;
    try {
      parsed = parseChatGptConversation(raw);
    } catch {
      parsed = null;
    }
    if (!parsed) {
      result.failed++;
      continue;
    }
    if (parsed.nodes.length === 0) {
      result.skipped++; // nothing a person would see
      continue;
    }
    if (parsed.extId && options.duplicates !== 'copy') {
      const existing = await store.db.get(
        'SELECT 1 AS found FROM session_meta WHERE ext_id = ? OR session_id = ? LIMIT 1',
        [parsed.extId, parsed.extId],
      );
      if (existing) {
        result.skipped++;
        continue;
      }
    }
    try {
      result.imported.push(await importOne(store, parsed));
    } catch {
      result.failed++;
    }
  }
  return result;
}

export async function importArchive(
  store: ConversationStore,
  bytes: Uint8Array,
  options?: ImportOptions,
): Promise<ImportResult> {
  return importConversations(store, readChatGptArchive(bytes), options);
}
