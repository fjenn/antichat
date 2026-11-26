/**
 * Text helpers shared by memory dedupe, retrieval and the "memory used"
 * attribution. Pure functions, no model.
 */

/** Lower case, accents removed, ß → ss, œ → oe. */
export function fold(text: string): string {
  return text
    .normalize('NFD')
    .replace(/\p{M}+/gu, '')
    .toLowerCase()
    .replace(/ß/g, 'ss')
    .replace(/œ/g, 'oe');
}

/**
 * The form two memories are compared in for exact duplicates: folded, the
 * leading "The user" / "User" / "I" dropped, punctuation and extra spaces
 * removed.
 */
export function normalizeFact(text: string): string {
  return fold(text)
    .replace(/[^\p{L}\p{N}\s]/gu, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/^(?:the )?user(?: s)?\b\s*/, '')
    .replace(/^(?:i am|i m|i)\b\s*/, '')
    .trim();
}

const STOPWORDS = new Set(
  (
    'a an and are as at be been but by can could did do does for from had has have he her hers him his how i if in into is it its ' +
    'just me my no not of on or our she so than that the their them then there these they this to too us user users was we were what ' +
    'when where which who why will with would you your yours about also am any being both each few more most other some such only own ' +
    'same very s t don should now like likes get got want wants please really always never often usually prefer prefers preferred ' +
    'der die das und ist ich du er sie es ein eine einen nicht mit auf fur von zu im in den dem des wie was mein meine dein ' +
    'le la les un une des et est je tu il elle nous vous de du en pour pas que qui mon ma mes ' +
    'el los las una y es yo en por para que mi mis con no se lo ' +
    'de het een en ik je is van voor met niet mijn'
  ).split(' '),
);

/** A light stemmer: enough to match plurals and verb endings in English. */
export function stem(word: string): string {
  if (word.length <= 3) {
    return word;
  }
  let out = word;
  if (word.endsWith('ies') && word.length > 5) {
    out = `${word.slice(0, -3)}y`;
  } else if (word.endsWith('ing') && word.length > 5) {
    out = word.slice(0, -3);
  } else if (
    word.endsWith('ed') &&
    word.length > 4 &&
    word[word.length - 3] !== 'e'
  ) {
    out = word.slice(0, -2);
  } else if (word.endsWith('es') && word.length > 5) {
    out = word.slice(0, -2);
  } else if (word.endsWith('s') && !word.endsWith('ss')) {
    out = word.slice(0, -1);
  }
  // "live", "lives", "lived" and "living" must meet: drop a final e.
  return out.length > 3 && out.endsWith('e') ? out.slice(0, -1) : out;
}

/** Folded words of `text`, in order. */
export function words(text: string): string[] {
  return fold(text)
    .split(/[^\p{L}\p{N}]+/u)
    .filter(word => word.length > 0);
}

/** Stemmed words that carry meaning (no stop words, no single letters). */
export function contentStems(text: string): string[] {
  const out: string[] = [];
  for (const word of words(text)) {
    if (STOPWORDS.has(word) || (word.length < 2 && !/\d/.test(word))) {
      continue;
    }
    out.push(stem(word));
  }
  return out;
}

export function stemSet(text: string): Set<string> {
  return new Set(contentStems(text));
}

/** Shared share of two sets: |A ∩ B| / |A ∪ B|. */
export function jaccard(a: Set<string>, b: Set<string>): number {
  if (a.size === 0 || b.size === 0) {
    return 0;
  }
  let shared = 0;
  for (const item of a) {
    if (b.has(item)) {
      shared++;
    }
  }
  return shared / (a.size + b.size - shared);
}

/** Share of `needle`'s stems that also occur in `haystack`. */
export function coverage(needle: Set<string>, haystack: Set<string>): number {
  if (needle.size === 0) {
    return 0;
  }
  let shared = 0;
  for (const item of needle) {
    if (haystack.has(item)) {
      shared++;
    }
  }
  return shared / needle.size;
}

/** FNV-1a over UTF-16 code units, two rounds: a 16-hex-digit key. */
/* eslint-disable no-bitwise */
export function hashText(text: string): string {
  let a = 0x811c9dc5;
  let b = 0x01000193;
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    a = Math.imul(a ^ code, 0x01000193) >>> 0;
    b = Math.imul(b ^ ((code << 5) | (code >>> 3)), 0x85ebca6b) >>> 0;
  }
  return a.toString(16).padStart(8, '0') + b.toString(16).padStart(8, '0');
}
/* eslint-enable no-bitwise */

/**
 * What a deleted memory leaves behind: a hash of its sorted content stems.
 * "User is vegetarian" and "Is a vegetarian" give the same signature, and
 * the text itself cannot be read back from it.
 */
export function factSignature(text: string): string {
  return hashText([...stemSet(normalizeFact(text))].sort().join(' '));
}

/**
 * Facts of which a person has one at a time. Two memories in the same slot
 * are the same fact, old and new ("lives in Munich" → "lives in Berlin").
 * English-centred on purpose: it is the fallback when no model is free to
 * decide; with a model the decision prompt handles every language.
 */
const SLOTS: Array<{slot: string; pattern: RegExp}> = [
  {
    slot: 'name',
    pattern:
      /^(?:(?:first |full |preferred |nick)?name is|is (?:called|named)|goes by|prefers to be called)\b/,
  },
  {
    slot: 'home',
    pattern:
      /\b(?:lives?|living|resides?|is based|based|moved|moving|relocated|relocating) (?:in|to|near)\b|\bhome (?:town|city) is\b/,
  },
  {
    slot: 'job',
    pattern:
      /\bworks? (?:as|at|for|in)\b|\bis an? (?:[\w-]+ ){0,3}(?:engineer|developer|programmer|designer|teacher|professor|lecturer|nurse|doctor|physician|dentist|lawyer|attorney|accountant|analyst|scientist|researcher|manager|consultant|architect|journalist|writer|editor|chef|cook|barista|waiter|waitress|driver|pilot|electrician|plumber|mechanic|carpenter|farmer|librarian|pharmacist|therapist|paramedic|firefighter|officer|soldier|salesperson|cashier|receptionist|translator|photographer|musician|actor|artist|freelancer|student|intern|founder|ceo|cto)\b|\bjob (?:title )?is\b|\bis employed\b|\boccupation\b|\bprofession\b|\b(?:starts?|starting|started) (?:a new job |work )?as\b|\bis now an? \b|\bnow works\b|\bnew (?:role|job|position)\b|\bjob as\b|\bleft (?:teaching|nursing|his job|her job|their job)\b/,
  },
  {
    slot: 'diet',
    pattern:
      /\b(?:vegetarian|vegan|pescatarian|omnivore|carnivore|keto|eats meat|does not eat meat|doesn t eat meat|no longer eats meat)\b/,
  },
  {
    slot: 'age',
    pattern:
      /\b(?:is|turned|turns) \d{1,3}(?: years old)?$|\bage is\b|\byears old\b/,
  },
  {slot: 'birthday', pattern: /\bbirthday\b|\bwas born on\b/},
  {slot: 'units', pattern: /\b(?:metric|imperial|celsius|fahrenheit)\b/},
  {
    slot: 'reply-language',
    pattern:
      /\b(?:answers?|repl(?:y|ies)|respon(?:d|ses?)) (?:should be |to be )?in (?:english|german|french|spanish|dutch|italian|portuguese)\b/,
  },
];

/** The single-valued slot a fact belongs to, if any. */
export function slotOf(text: string): string | null {
  const normalized = normalizeFact(text);
  for (const {slot, pattern} of SLOTS) {
    if (pattern.test(normalized)) {
      return slot;
    }
  }
  return null;
}

/** Collapse whitespace and cut at a word to at most `limit` characters. */
export function clip(text: string, limit: number): string {
  const flat = text.replace(/\s+/g, ' ').trim();
  if (flat.length <= limit) {
    return flat;
  }
  const cut = flat.slice(0, limit);
  const space = cut.lastIndexOf(' ');
  return `${(space > limit * 0.6 ? cut.slice(0, space) : cut).trimEnd()}…`;
}

/**
 * An FTS5 query that matches any of the content words of `text` (ranked by
 * bm25, so more shared words rank higher). Null when nothing is left.
 */
export function anyWordQuery(
  text: string,
  maxTerms: number = 12,
): string | null {
  const seen = new Set<string>();
  const terms: string[] = [];
  for (const word of words(text.normalize('NFKC'))) {
    if (STOPWORDS.has(word) || word.length < 2 || seen.has(word)) {
      continue;
    }
    seen.add(word);
    terms.push(`"${word}"`);
    if (terms.length >= maxTerms) {
      break;
    }
  }
  return terms.length ? terms.join(' OR ') : null;
}

export function isStopword(word: string): boolean {
  return STOPWORDS.has(word);
}

/** Words too common to tie two texts together on their own. */
const GENERIC = new Set(
  'user name live liv work like love lov prefer want use year old time day week month thing good make mak need help know think people way new'.split(
    ' ',
  ),
);

/** Do two sets of stems share something specific? */
export function sharesTopic(a: Set<string>, b: Set<string>): boolean {
  let shared = 0;
  for (const item of a) {
    if (!b.has(item)) {
      continue;
    }
    if (!GENERIC.has(item) && item.length >= 4) {
      return true;
    }
    shared++;
  }
  return shared >= 2;
}
