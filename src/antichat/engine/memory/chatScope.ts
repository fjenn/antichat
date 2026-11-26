/**
 * What memory needs to know about a chat: is it temporary, which project is
 * it in, and does that project keep its memory to itself. Read from
 * antichat.db (`session_meta` belongs to M3, `projects` to the projects
 * namespace); a chat without a row yet is an ordinary chat.
 */
import type {Db} from '../store/driver';
import {isOfflineChat} from '../offline';
import {getChatFlags} from '../store/read';
import type {MemoryScope} from './types';

export interface ChatInfo {
  sessionId?: string | null;
  temporary: boolean;
  /** Offline chat: saved memories are used, nothing new is written. */
  readOnly?: boolean;
  scope: MemoryScope;
  /** Projects whose chats and memories stay inside the project. */
  isolatedProjectIds: string[];
}

export type ChatResolver = (sessionId?: string | null) => Promise<ChatInfo>;

/** `project-only` projects, or none when the projects schema is absent. */
export async function isolatedProjects(db: Db): Promise<string[]> {
  try {
    const rows = await db.all<{id: string}>(
      "SELECT id FROM projects WHERE memory_scope = 'project'",
    );
    return rows.map(row => row.id);
  } catch {
    return [];
  }
}

export function createChatResolver(db: Db): ChatResolver {
  return async sessionId => {
    const isolatedProjectIds = await isolatedProjects(db);
    if (!sessionId) {
      return {sessionId, temporary: false, scope: {}, isolatedProjectIds};
    }
    const flags = await getChatFlags(db, sessionId);
    const projectId = flags?.projectId ?? null;
    return {
      sessionId,
      temporary: flags?.temporary === true,
      readOnly: isOfflineChat(sessionId),
      scope: projectId
        ? {projectId, projectOnly: isolatedProjectIds.includes(projectId)}
        : {},
      isolatedProjectIds,
    };
  };
}
