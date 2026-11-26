/**
 * Wording of the project screens. Our own; kept beside the screens until the
 * integration lane moves it into `locales/en.json` (a shared file).
 */
const en = {
  title: 'Projects',
  newProject: 'New project',
  namePlaceholder: 'Project name',
  create: 'Create',
  save: 'Save',
  cancel: 'Cancel',
  empty: 'No projects yet',
  emptyHint:
    'A project keeps related chats together and gives them shared instructions.',
  chats: '{{count}} chats',
  chatsOne: '1 chat',
  noChats: 'No chats',
  instructions: 'Instructions',
  instructionsHint: 'How AntiChat should answer in this project',
  instructionsPlaceholder:
    'For example: answer in German, keep a formal tone, assume I use Python.',
  instructionsEmpty: 'Add instructions',
  files: 'Files',
  filesEmpty: 'No files in this project',
  filePending: 'Reading…',
  fileFailed: 'Could not be read',
  chatsTitle: 'Chats',
  chatsEmpty: 'Chats in this project appear here',
  newChat: 'New chat in this project',
  untitled: 'New chat',
  more: 'Project options',
  rename: 'Rename',
  renameTitle: 'Rename project',
  delete: 'Delete project',
  deleteTitle: 'Delete this project?',
  deleteBody:
    'Its chats, files and memories are deleted from this phone. This cannot be undone.',
  deleted: 'Project deleted',
  missing: 'This project no longer exists',
  move: 'Move to project',
  moved: 'Moved to {{name}}',
  removeFromProject: 'Remove from project',
  removed: 'Removed from project',
  failed: 'That did not work',
  seeAll: 'All projects',
} as const;

export type ProjectStringKey = keyof typeof en;

export function ps(
  key: ProjectStringKey,
  params?: Record<string, string | number>,
): string {
  const template: string = en[key];
  if (!params) {
    return template;
  }
  return template.replace(/\{\{(\w+)\}\}/g, (match, name: string) =>
    name in params ? String(params[name]) : match,
  );
}

export function chatCount(count: number): string {
  if (count === 0) {
    return ps('noChats');
  }
  return count === 1 ? ps('chatsOne') : ps('chats', {count});
}
