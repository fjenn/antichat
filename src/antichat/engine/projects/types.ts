/** Shapes of the projects engine (M9). */

/**
 * - `default`: chats in the project also use global memories and can
 *   reference chats outside it.
 * - `project`: "project-only memory". The project's chats read and write
 *   only the project's own memories and reference only its own chats, and
 *   nothing from the project is referenced outside it.
 */
export type ProjectMemoryScope = 'default' | 'project';

export interface Project {
  id: string;
  name: string;
  /** Shared instructions, applied to every chat in the project. */
  instructions: string;
  memoryScope: ProjectMemoryScope;
  /** Free-form presentation data for the UI (icon, colour). */
  appearance: Record<string, unknown>;
  createdAt: number;
  updatedAt: number;
  archivedAt: number | null;
}

/** How far the files pipeline (M10) has got with a file. */
export type ProjectFileStatus = 'pending' | 'ready' | 'failed';

/** A file attached to a project: a reference row; M10 owns the content. */
export interface ProjectFile {
  id: string;
  projectId: string;
  name: string;
  mimeType: string | null;
  size: number | null;
  uri: string | null;
  status: ProjectFileStatus;
  createdAt: number;
}

export interface NewProjectFile {
  name: string;
  mimeType?: string | null;
  size?: number | null;
  uri?: string | null;
  status?: ProjectFileStatus;
}

export interface ProjectSummary extends Project {
  chatCount: number;
  fileCount: number;
  memoryCount: number;
  /** Newest change among the project's chats, for sorting. */
  lastChatAt: number | null;
}

/** What the project store needs from the conversation store (M3). */
export interface ProjectChats {
  setProject(sessionId: string, projectId: string | null): Promise<void>;
  deleteSessions(sessionIds: string[]): Promise<void>;
}

export const MAX_PROJECT_NAME_CHARS = 80;
export const MAX_PROJECT_INSTRUCTIONS_CHARS = 8000;
/** ChatGPT's own limit per project on the free tier is 20 files. */
export const MAX_PROJECT_FILES = 20;
