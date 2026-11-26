import type {ConversationPort} from '../../contracts';
import type {ProjectFileRow, ProjectRow, ProjectsUi} from './types';

interface FakeProject {
  id: string;
  name: string;
  instructions: string;
  updatedAt: number;
  files: ProjectFileRow[];
}

export interface FakeProjectsOptions {
  now?: () => number;
  /** Start with two example projects (the default) or with none. */
  seed?: boolean;
}

const DAY = 24 * 60 * 60 * 1000;

/**
 * Projects in memory over the contract's conversation port (normally
 * `FakeConversations`). The contract has no "move chat", so membership is
 * kept here and laid over `ConversationView.projectId`.
 */
export function createFakeProjectsUi(
  conversations: ConversationPort,
  options: FakeProjectsOptions = {},
): ProjectsUi {
  const now = options.now ?? Date.now;
  const listeners = new Set<() => void>();
  const emit = () => listeners.forEach(listener => listener());
  conversations.subscribe(emit);

  let nextId = 1;
  let projects: FakeProject[] = [];
  /** Chat id → project id, or null for "moved out". */
  const moved = new Map<string, string | null>();

  const make = (name: string, instructions: string, age: number) => {
    const project: FakeProject = {
      id: `prj${nextId++}`,
      name,
      instructions,
      updatedAt: now() - age,
      files: [],
    };
    projects = [project, ...projects];
    return project;
  };
  if (options.seed !== false) {
    make('Trip to Lisbon', 'Keep answers short. Prices in euros.', 3 * DAY);
    const work = make('Work notes', '', DAY);
    work.files = [
      {id: 'file1', name: 'Roadmap.pdf', status: 'ready', sizeBytes: 482_000},
    ];
  }

  const projectIdOf = (chatId: string): string | null => {
    if (moved.has(chatId)) {
      return moved.get(chatId) ?? null;
    }
    return conversations.get(chatId)?.projectId ?? null;
  };
  const chatsOf = (projectId: string) =>
    conversations.conversations.filter(
      chat => !chat.temporary && projectIdOf(chat.id) === projectId,
    );
  const toRow = (project: FakeProject): ProjectRow => {
    const chats = chatsOf(project.id);
    return {
      id: project.id,
      name: project.name,
      instructions: project.instructions,
      chatCount: chats.length,
      fileCount: project.files.length,
      updatedAt: Math.max(
        project.updatedAt,
        ...chats.map(chat => chat.updatedAt),
      ),
    };
  };
  const find = (id: string) => projects.find(project => project.id === id);

  return {
    subscribe(listener) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    list: async () =>
      projects.map(toRow).sort((a, b) => b.updatedAt - a.updatedAt),
    async get(id) {
      const project = find(id);
      return project ? toRow(project) : null;
    },
    async create(name, instructions = '') {
      const clean = name.trim();
      if (!clean) {
        throw new Error('A project needs a name');
      }
      const project = make(clean, instructions, 0);
      emit();
      return toRow(project);
    },
    async update(id, patch) {
      const project = find(id);
      if (!project) {
        return;
      }
      if (patch.name !== undefined && patch.name.trim()) {
        project.name = patch.name.trim();
      }
      if (patch.instructions !== undefined) {
        project.instructions = patch.instructions;
      }
      project.updatedAt = now();
      emit();
    },
    async remove(id) {
      const chats = chatsOf(id);
      projects = projects.filter(project => project.id !== id);
      for (const chat of chats) {
        moved.delete(chat.id);
        await conversations.remove(chat.id);
      }
      emit();
    },
    chats: async projectId =>
      chatsOf(projectId).map(chat => ({
        id: chat.id,
        title: chat.title,
        updatedAt: chat.updatedAt,
      })),
    files: async projectId => find(projectId)?.files ?? [],
    async projectOf(conversationId) {
      const id = projectIdOf(conversationId);
      const project = id ? find(id) : undefined;
      return project ? toRow(project) : null;
    },
    async moveChat(conversationId, projectId) {
      if (projectId && !find(projectId)) {
        throw new Error(`Unknown project ${projectId}`);
      }
      moved.set(conversationId, projectId);
      const project = projectId ? find(projectId) : undefined;
      if (project) {
        project.updatedAt = now();
      }
      emit();
    },
    async startChat(projectId) {
      const chat = await conversations.create({projectId});
      return chat.id;
    },
  };
}
