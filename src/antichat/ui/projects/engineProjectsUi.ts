import type {ProjectStore} from '../../engine/projects/ProjectStore';
import type {ProjectSummary} from '../../engine/projects/types';
import type {SessionMeta} from '../../engine/store/types';
import type {ProjectRow, ProjectsUi} from './types';

/** The part of the conversation store (M3) the project screens read. */
export interface ProjectConversations {
  subscribe(listener: () => void): () => void;
  getMeta(sessionId: string): Promise<SessionMeta | null>;
}

export interface EngineProjectsOptions {
  projects: ProjectStore;
  conversations: ProjectConversations;
  /**
   * Makes the next chat the user starts land in the project. Without it
   * "New chat in this project" opens a plain new chat.
   */
  startChat?: (projectId: string) => Promise<string | null>;
}

export type EngineProjectsUi = ProjectsUi & {dispose(): void};

function toRow(summary: ProjectSummary): ProjectRow {
  return {
    id: summary.id,
    name: summary.name,
    instructions: summary.instructions,
    chatCount: summary.chatCount,
    fileCount: summary.fileCount,
    updatedAt: Math.max(summary.lastChatAt ?? 0, summary.updatedAt),
  };
}

/** The project screens on M9's engine (`engine.projects`). */
export function createEngineProjectsUi(
  options: EngineProjectsOptions,
): EngineProjectsUi {
  const {projects, conversations} = options;
  const listeners = new Set<() => void>();
  const emit = () => listeners.forEach(listener => listener());
  const offs = [projects.subscribe(emit), conversations.subscribe(emit)];

  const list = async () => (await projects.list()).map(toRow);
  const get = async (id: string) =>
    (await list()).find(project => project.id === id) ?? null;

  return {
    subscribe(listener) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    list,
    get,
    async create(name, instructions) {
      const created = await projects.create({name, instructions});
      return (await get(created.id))!;
    },
    async update(id, patch) {
      await projects.update(id, patch);
    },
    async remove(id) {
      await projects.delete(id);
    },
    async chats(projectId) {
      const ids = await projects.sessionIds(projectId);
      const metas = await Promise.all(ids.map(id => conversations.getMeta(id)));
      return metas
        .filter((meta): meta is SessionMeta => meta !== null)
        .filter(meta => meta.archivedAt === null)
        .map(meta => ({
          id: meta.sessionId,
          title: meta.title,
          updatedAt: meta.updatedAt,
        }));
    },
    async files(projectId) {
      return (await projects.listFiles(projectId)).map(file => ({
        id: file.id,
        name: file.name,
        status: file.status,
        sizeBytes: file.size,
      }));
    },
    async projectOf(conversationId) {
      const project = await projects.projectOfSession(conversationId);
      return project ? get(project.id) : null;
    },
    async moveChat(conversationId, projectId) {
      await projects.moveChat(conversationId, projectId);
    },
    async startChat(projectId) {
      return options.startChat ? options.startChat(projectId) : null;
    },
    dispose() {
      offs.forEach(off => off());
      listeners.clear();
    },
  };
}
