/**
 * Wording of the memory screens. Our own; nothing copied from ChatGPT. Kept
 * beside the screens until the integration lane moves it into
 * `locales/en.json` (a shared file).
 */
const en = {
  title: 'Memories',
  search: 'Search memories',
  add: 'Add a memory',
  addPlaceholder: 'Something to remember about you',
  edit: 'Edit memory',
  save: 'Save',
  cancel: 'Cancel',
  delete: 'Delete',
  undo: 'Undo',
  done: 'Done',
  deleteAll: 'Delete all memories',
  deleteAllTitle: 'Delete all memories?',
  deleteAllBody:
    'Everything AntiChat remembers about you is removed from this phone. This cannot be undone.',
  deleteAllConfirm: 'Delete all',
  deleted: 'Memory deleted',
  deletedAll: 'All memories deleted',
  saved: 'Memory saved',
  duplicate: 'Already remembered',
  rejected: 'Could not save that',
  pause: 'Pause memory',
  pauseHint: 'Saved memories are still used. Nothing new is saved.',
  off: 'Memory is off. Nothing is saved or used.',
  turnOn: 'Turn on',
  empty: 'Nothing remembered yet',
  emptyHint:
    'Tell AntiChat something worth keeping, like "remember that I am vegetarian".',
  noResults: 'No memory matches "{{query}}"',
  originSaved: 'Saved by you',
  originLearned: 'Learned from a chat',
  count: '{{count}} memories',
  countOne: '1 memory',
  updated: 'Memory updated',
  updatedHint: 'Shows what was saved',
  wasBefore: 'Before: {{text}}',
  manage: 'Manage memories',
  used: 'Memory used',
  usedTitle: 'Memories used for this answer',
  usedAlso: 'Also available to this answer',
  settingsEnabled: 'Saved memories',
  settingsEnabledHint: 'Remember things about you and use them in new chats.',
  settingsChats: 'Reference past chats',
  settingsChatsHint: 'Use recent chats to give better answers.',
  back: 'Back',
} as const;

export type MemoryStringKey = keyof typeof en;

export function ms(
  key: MemoryStringKey,
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
