import type {ModelLanguages} from '../../contracts';

/**
 * At this many languages a model reads as "Multilingual": the store card gets
 * the tag and Details sums the list up instead of spelling it out.
 */
export const MULTILINGUAL_MIN = 8;

/** English names for the ISO 639 codes model cards use. */
const NAMES: Record<string, string> = {
  ar: 'Arabic',
  cs: 'Czech',
  da: 'Danish',
  de: 'German',
  el: 'Greek',
  en: 'English',
  es: 'Spanish',
  fa: 'Persian',
  fi: 'Finnish',
  fr: 'French',
  he: 'Hebrew',
  hi: 'Hindi',
  hu: 'Hungarian',
  id: 'Indonesian',
  it: 'Italian',
  ja: 'Japanese',
  ko: 'Korean',
  ms: 'Malay',
  nl: 'Dutch',
  no: 'Norwegian',
  pl: 'Polish',
  pt: 'Portuguese',
  ro: 'Romanian',
  ru: 'Russian',
  sv: 'Swedish',
  th: 'Thai',
  tr: 'Turkish',
  uk: 'Ukrainian',
  vi: 'Vietnamese',
  zh: 'Chinese',
};

/** Language names, English first, in the card's order otherwise. */
export function languageNames(codes: readonly string[]): string[] {
  const unique = [...new Set(codes)];
  const ordered = unique.includes('en')
    ? ['en', ...unique.filter(code => code !== 'en')]
    : unique;
  return ordered.map(code => NAMES[code] ?? code.toUpperCase());
}

/** How many languages, as a label: "11", "140+". Null when unknown. */
export function languageCount(languages?: ModelLanguages): string | null {
  const listed = languages?.codes?.length ?? 0;
  const count = Math.max(listed, languages?.count ?? 0);
  if (count === 0) {
    return null;
  }
  return languages?.atLeast && !listed ? `${count}+` : String(count);
}

export function isMultilingual(languages?: ModelLanguages): boolean {
  const listed = languages?.codes?.length ?? 0;
  return Math.max(listed, languages?.count ?? 0) >= MULTILINGUAL_MIN;
}
