/**
 * What the project screens ask for. Two implementations: `engineProjectsUi`
 * over M9's `ProjectStore` and the conversation store, and `fakeProjectsUi`
 * over the contract fake, which the tests and an app without the engine use.
 */
export interface ProjectRow {
  id: string;
  name: string;
  instructions: string;
  chatCount: number;
  fileCount: number;
  updatedAt: number;
}

export interface ProjectChatRow {
  id: string;
  title: string;
  updatedAt: number;
}

export interface ProjectFileRow {
  id: string;
  name: string;
  status: 'pending' | 'ready' | 'failed';
  sizeBytes: number | null;
}

export interface ProjectsUi {
  subscribe(listener: () => void): () => void;
  /** Most recently active first. */
  list(): Promise<ProjectRow[]>;
  get(id: string): Promise<ProjectRow | null>;
  create(name: string, instructions?: string): Promise<ProjectRow>;
  update(
    id: string,
    patch: {name?: string; instructions?: string},
  ): Promise<void>;
  /** Deletes the project with its chats, files and memories. */
  remove(id: string): Promise<void>;
  chats(projectId: string): Promise<ProjectChatRow[]>;
  files(projectId: string): Promise<ProjectFileRow[]>;
  projectOf(conversationId: string): Promise<ProjectRow | null>;
  /** Moves a chat into a project, or out of any project with `null`. */
  moveChat(conversationId: string, projectId: string | null): Promise<void>;
  /**
   * Starts a chat in the project. Resolves the id of the chat to open, or
   * `null` when the caller should show the empty new chat: the chat is
   * created by the first message and lands in the project then.
   */
  startChat(projectId: string): Promise<string | null>;
}

export const MAX_PROJECT_NAME = 80;
export const MAX_PROJECT_INSTRUCTIONS = 8000;
