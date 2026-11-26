/**
 * Is a tool a write, judged by its name? Port of the Mac's `VerbClassifier`:
 * the name is split into words and searched for a write verb; a write verb
 * anywhere wins (`search_and_delete` is a write). Names only, never arguments.
 */
export type VerbKind = 'write' | 'read' | 'unknown';

const WRITE = new Set(
  'send create delete update post reply move archive remove add insert patch put upload share invite merge close assign'.split(
    ' ',
  ),
);
const READ = new Set(
  'get list search fetch read find query retrieve view count check download export lookup describe whoami profile show ask explain summarize'.split(
    ' ',
  ),
);

/** `GMAIL_SEND_EMAIL`, `createIssue`, `files.delete` → lower-case words. */
export function nameWords(name: string): string[] {
  return name
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter(Boolean);
}

export function classifyVerb(name: string): VerbKind {
  const words = nameWords(name);
  if (words.some(word => WRITE.has(word))) {
    return 'write';
  }
  if (words.some(word => READ.has(word))) {
    return 'read';
  }
  return 'unknown';
}

export interface WriteHints {
  readOnly?: boolean;
  create?: boolean;
  update?: boolean;
  destructive?: boolean;
}

/**
 * Write-type by hints, else by verb. A name the verb rule cannot place
 * counts as a write: it asks.
 */
export function isWriteAction(
  name: string,
  hints?: WriteHints | null,
): boolean {
  if (hints) {
    if (hints.destructive || hints.create || hints.update) {
      return true;
    }
    if (hints.readOnly) {
      return false;
    }
  }
  return classifyVerb(name) !== 'read';
}
