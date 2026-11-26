/**
 * Pronunciation fixes: words the voices get wrong, replaced by a spelling
 * they get right, before synthesis. A small built-in list plus the user's own
 * entries (Settings > Voice), which win over the built-ins.
 */

export interface PronunciationEntry {
  /** The written form, matched as a whole word. */
  word: string;
  /** What the voice should read instead. */
  say: string;
  /** Limit to one language (BCP-47 base, e.g. "en"); all when absent. */
  language?: string;
  /** Match upper and lower case exactly (acronyms). Default false. */
  caseSensitive?: boolean;
}

export const BUILTIN_PRONUNCIATIONS: readonly PronunciationEntry[] = [
  {word: 'AntiChat', say: 'Anti Chat'},
  {word: 'GGUF', say: 'G G U F', caseSensitive: true},
  {word: 'LLM', say: 'L L M', caseSensitive: true},
  {word: 'LLMs', say: 'L L Ms', caseSensitive: true},
  {word: 'iOS', say: 'eye O S', language: 'en', caseSensitive: true},
  {word: 'macOS', say: 'mac O S', language: 'en', caseSensitive: true},
  {word: 'iPadOS', say: 'eye pad O S', language: 'en', caseSensitive: true},
  {word: 'SQL', say: 'sequel', language: 'en', caseSensitive: true},
  {word: 'JSON', say: 'jason', language: 'en', caseSensitive: true},
  {word: 'GUI', say: 'gooey', language: 'en', caseSensitive: true},
  {word: 'API', say: 'A P I', caseSensitive: true},
  {word: 'APIs', say: 'A P Is', caseSensitive: true},
  {word: 'URL', say: 'U R L', caseSensitive: true},
  {word: 'CPU', say: 'C P U', caseSensitive: true},
  {word: 'GPU', say: 'G P U', caseSensitive: true},
  {word: 'Wi-Fi', say: 'why fye', language: 'en'},
  {word: 'WiFi', say: 'why fye', language: 'en'},
  {word: 'Qwen', say: 'chwen', language: 'en'},
  {word: 'Kokoro', say: 'ko ko ro', language: 'en'},
  {word: 'TTS', say: 'T T S', caseSensitive: true},
  {word: 'UI', say: 'U I', caseSensitive: true},
];

const escape = (text: string) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const base = (tag?: string) => (tag ?? '').toLowerCase().split(/[-_]/)[0]!;

export class PronunciationLexicon {
  private user: PronunciationEntry[] = [];
  private compiled: {pattern: RegExp; say: string; language?: string}[] = [];

  constructor(
    user: readonly PronunciationEntry[] = [],
    private readonly builtins: readonly PronunciationEntry[] = BUILTIN_PRONUNCIATIONS,
  ) {
    this.setUserEntries(user);
  }

  get userEntries(): readonly PronunciationEntry[] {
    return this.user;
  }

  setUserEntries(entries: readonly PronunciationEntry[]): void {
    this.user = entries
      .map(e => ({...e, word: e.word.trim(), say: e.say.trim()}))
      .filter(e => e.word && e.say);
    this.compile();
  }

  /** Adds or replaces the entry for `word`. */
  add(entry: PronunciationEntry): void {
    this.setUserEntries([
      ...this.user.filter(
        e => e.word.toLowerCase() !== entry.word.trim().toLowerCase(),
      ),
      entry,
    ]);
  }

  remove(word: string): void {
    this.setUserEntries(
      this.user.filter(e => e.word.toLowerCase() !== word.trim().toLowerCase()),
    );
  }

  apply(text: string, language?: string): string {
    const lang = base(language);
    let out = text;
    for (const rule of this.compiled) {
      if (!rule.language || !lang || rule.language === lang) {
        out = out.replace(rule.pattern, rule.say);
      }
    }
    return out;
  }

  /** For settings storage. */
  toJSON(): PronunciationEntry[] {
    return [...this.user];
  }

  private compile(): void {
    const seen = new Set<string>();
    const rules: typeof this.compiled = [];
    // User entries first: they shadow a built-in for the same word.
    for (const entry of [...this.user, ...this.builtins]) {
      const key = `${entry.word.toLowerCase()}|${base(entry.language)}`;
      if (seen.has(key) || seen.has(`${entry.word.toLowerCase()}|`)) {
        continue;
      }
      seen.add(key);
      rules.push({
        pattern: new RegExp(
          `(?<![\\p{L}\\p{N}])${escape(entry.word)}(?![\\p{L}\\p{N}])`,
          entry.caseSensitive ? 'gu' : 'giu',
        ),
        say: entry.say,
        language: entry.language ? base(entry.language) : undefined,
      });
    }
    // Longer words first, so "APIs" is not caught by "API".
    this.compiled = rules.sort(
      (a, b) => b.pattern.source.length - a.pattern.source.length,
    );
  }
}
