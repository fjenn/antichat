/**
 * Query rewriting by rules (H5): what the harness sends to the engines when
 * it searches itself, and the clean-up applied to a query the model wrote.
 *
 *   - follow-up resolution: "and in Germany?" → topic words of the previous
 *     question are appended
 *   - date awareness: "today", "this week", "last weekend", "latest" → the
 *     month and year are added, so engines do not return last year's page
 *   - language: the query stays in the user's language; the detected language
 *     picks the Wikipedia edition and the engines' region parameter
 *   - sub-queries for two-part questions (port of the Mac `SearchQuerySplit`)
 *
 * No model call: on the Mac the model step cost ~2.5 s and wrote nearly the
 * same query as the user's own words.
 */

export const MAX_QUERY_LENGTH = 200;

const MONTHS = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

const LEAD_IN =
  /^(?:(?:hey|hi|ok|okay|please|pls|can you|could you|would you|will you|i need you to|i want you to|i'd like you to|kannst du|könntest du|bitte|puedes|peux-tu|kun je)\s+)*(?:(?:please\s+)?(?:search (?:the web |the internet |online )?(?:for|up)|look up|google|find out|find me|find|check|tell me|show me|give me|let me know|do you know|i(?:'d| would) like to know|i want to know|i wonder|such(?:e)? (?:nach|mal nach)?|sag mir|zeig mir|busca|dime|cherche|dis-moi|zoek(?: op)?)\s+)?/i;

const TRAILERS =
  /\s*(?:please|pls|thanks|thank you|thx|for me|right now\??|bitte|danke|por favor|gracias|s'il (?:te|vous) pla[iî]t|merci|alsjeblieft)[\s.!?]*$/i;

const STOPWORDS = new Set([
  'the',
  'a',
  'an',
  'of',
  'in',
  'on',
  'for',
  'to',
  'and',
  'or',
  'is',
  'are',
  'was',
  'were',
  'what',
  'when',
  'which',
  'who',
  'whom',
  'whose',
  'where',
  'why',
  'how',
  'does',
  'do',
  'did',
  'will',
  'can',
  'has',
  'have',
  'with',
  'about',
  'from',
  'by',
  'at',
  'as',
  'be',
  "what's",
  "who's",
  'compare',
  'tell',
  'me',
  'please',
  'it',
  'its',
  'this',
  'that',
  'there',
  'any',
  'some',
  'i',
  'you',
  'my',
  'your',
  'we',
  'they',
  'them',
  'their',
  'much',
  'many',
  'so',
  'der',
  'die',
  'das',
  'ein',
  'eine',
  'und',
  'oder',
  'ist',
  'sind',
  'wie',
  'was',
  'wer',
  'wo',
  'el',
  'la',
  'los',
  'las',
  'un',
  'una',
  'y',
  'o',
  'es',
  'son',
  'qué',
  'quién',
  'cómo',
  'le',
  'les',
  'une',
  'et',
  'ou',
  'est',
  'sont',
  'que',
  'qui',
  'comment',
]);

const BACK_REFERENCES = new Set([
  'it',
  'its',
  'they',
  'their',
  'them',
  'he',
  'his',
  'she',
  'her',
  'this',
  'these',
  'those',
  'that',
  'there',
  'one',
  'ones',
  'same',
  'es',
  'er',
  'sie',
  'ihr',
  'dort',
  'das',
  'diese',
  'dieser',
  'él',
  'ella',
  'eso',
  'allí',
  'il',
  'elle',
  'ça',
  'cela',
  'het',
  'ze',
  'daar',
]);

const FOLLOW_UP_START =
  /^(?:and|what about|how about|and what about|also|but|or|then|what if|und|und was ist mit|was ist mit|wie (?:ist es|sieht es) (?:mit|in)|y|y qué|qué tal|et|et pour|en|e)\b/i;

export type QueryLanguage =
  | 'en'
  | 'de'
  | 'es'
  | 'fr'
  | 'nl'
  | 'pt'
  | 'it'
  | 'other';

const LANGUAGE_HINTS: Array<[QueryLanguage, RegExp]> = [
  [
    'de',
    /\b(?:der|die|das|und|ist|nicht|wie|was|wer|ein|eine|für|mit|aktuell|heute|gibt|kostet|teuer|wann|welche[rs]?)\b|[äöüß]/gi,
  ],
  [
    'es',
    /\b(?:qué|cómo|cuál|cuándo|dónde|quién|para|hoy|está|precio|cuánto|del|una|por|cuesta|tiene)\b|[¿¡ñ]/gi,
  ],
  [
    'fr',
    /\b(?:le|les|des|est|quel(?:le)?s?|comment|pourquoi|quand|où|avec|pour|aujourd'hui|combien|prix)\b|[çœ]|\b(?:qu|l|d|j)'/gi,
  ],
  [
    'nl',
    /\b(?:het|een|en|niet|wat|hoe|wie|waar|wanneer|vandaag|voor|met|hoeveel|kost)\b/gi,
  ],
  [
    'pt',
    /\b(?:os|as|um|uma|não|como|quando|onde|quem|hoje|para|com|quanto|preço|está)\b|[ãõ]/gi,
  ],
  [
    'it',
    /\b(?:il|gli|che|come|quando|dove|chi|oggi|per|con|quanto|prezzo|è|sono)\b/gi,
  ],
  [
    'en',
    /\b(?:the|is|are|what|how|who|when|where|why|does|did|with|for|today|price|much|latest)\b/gi,
  ],
];

/** Coarse language guess from function words; `other` for non-Latin scripts. */
export function detectLanguage(text: string): QueryLanguage {
  return scoreLanguage(text).language;
}

/** The guess with the number of hint words behind it (0 = no signal). */
export function scoreLanguage(text: string): {
  language: QueryLanguage;
  score: number;
} {
  if (/[Ѐ-ӿ؀-ۿ぀-ヿ一-鿿가-힯֐-׿฀-๿]/.test(text)) {
    return {language: 'other', score: 9};
  }
  let best: QueryLanguage = 'en';
  let bestScore = 0;
  for (const [language, pattern] of LANGUAGE_HINTS) {
    const score = (text.match(pattern) ?? []).length;
    if (score > bestScore) {
      best = language;
      bestScore = score;
    }
  }
  return {language: best, score: bestScore};
}

const contentWords = (text: string): string[] =>
  text
    .split(/[^\p{L}\p{N}.'-]+/u)
    .map(word => word.replace(/^[.'-]+|[.'-]+$/g, ''))
    .filter(word => word.length > 1 && !STOPWORDS.has(word.toLowerCase()));

/** Lead-ins and politeness removed; the question itself is kept verbatim. */
export function stripLeadIn(text: string): string {
  let out = text.replace(/\s+/g, ' ').trim();
  out = out.replace(TRAILERS, '').replace(LEAD_IN, '').trim();
  // "whether", "if" left over from "tell me if …"
  out = out.replace(/^(?:if|whether|ob|si)\s+/i, '');
  return out.replace(/[\s?.!,;]+$/g, '').trim();
}

/** Does the message lean on the previous turn for its subject? */
export function isFollowUp(text: string): boolean {
  const trimmed = text.trim();
  if (FOLLOW_UP_START.test(trimmed)) {
    return true;
  }
  const words = trimmed
    .toLowerCase()
    .split(/[^\p{L}\p{N}']+/u)
    .filter(Boolean);
  const content = contentWords(trimmed);
  const refers = words.some(word => BACK_REFERENCES.has(word));
  // A bare reference ("is it open today?") or a fragment ("in Germany?").
  return (refers && content.length <= 4) || content.length <= 1;
}

/** Topic words of an earlier user message: its names and long nouns. */
export function topicWords(previous: string, limit = 5): string[] {
  const words = contentWords(stripLeadIn(previous));
  const names = words.filter(word => /[\p{Lu}\d]/u.test(word));
  const rest = words.filter(word => !names.includes(word) && word.length > 3);
  return [...new Set([...names, ...rest])].slice(0, limit);
}

/** "today" → "24 November 2026"; "latest" → the year; and so on. */
export function dateHints(text: string, now: Date): string[] {
  const lowered = text.toLowerCase();
  const year = String(now.getFullYear());
  const month = `${MONTHS[now.getMonth()]} ${year}`;
  if (/(?:19|20)\d{2}/.test(text)) {
    return [];
  }
  if (
    /\b(?:today|tonight|right now|now|heute|jetzt|hoy|ahora|aujourd'hui|maintenant|vandaag|hoje|agora|oggi)\b/.test(
      lowered,
    )
  ) {
    return [`${now.getDate()} ${month}`];
  }
  if (
    /\b(?:yesterday|tomorrow|this (?:week|weekend|month|morning|evening)|last (?:week|weekend|night|month)|next week|recently|lately|diese woche|letzte[sn]? (?:woche|wochenende)|gestern|morgen|esta semana|ayer|mañana|cette semaine|hier|demain|deze week|gisteren|ontem|amanhã)\b/.test(
      lowered,
    )
  ) {
    return [month];
  }
  if (
    /\b(?:latest|newest|current(?:ly)?|most recent|upcoming|this year|so far|aktuell(?:e[rsnm]?)?|derzeit|neueste[rsn]?|actual(?:es|mente)?|últim[oa]s?|actuel(?:le)?s?|dernière?s?|huidige|nieuwste|atual|mais recente)\b/.test(
      lowered,
    )
  ) {
    return [year];
  }
  return [];
}

export interface QueryPlan {
  /** Queries to run, most important first. */
  queries: string[];
  language: QueryLanguage;
  /** The first query was completed from the previous turn. */
  resolvedFollowUp: boolean;
}

export interface QueryInput {
  userText: string;
  /** Earlier user messages, oldest first. */
  previousUserTexts?: string[];
  now: Date;
  /** How many queries the device class allows (A: 1 … C+: 3). */
  maxQueries?: number;
  /** Language of the app, used when the text gives no signal. */
  locale?: string;
}

const clip = (query: string): string => {
  const text = query.replace(/\s+/g, ' ').trim();
  if (text.length <= MAX_QUERY_LENGTH) {
    return text;
  }
  const cut = text.slice(0, MAX_QUERY_LENGTH);
  return cut.slice(0, Math.max(cut.lastIndexOf(' '), 60)).trim();
};

/** The queries the harness sends for a user message. */
export function buildQueries(input: QueryInput): QueryPlan {
  const max = Math.max(1, input.maxQueries ?? 1);
  const language = detectLanguage(
    [input.userText, ...(input.previousUserTexts ?? []).slice(-1)].join(' '),
  );
  let base = stripLeadIn(input.userText);
  let resolvedFollowUp = false;
  const previous = (input.previousUserTexts ?? []).filter(Boolean);
  if (previous.length > 0 && isFollowUp(input.userText)) {
    const have = new Set(contentWords(base).map(word => word.toLowerCase()));
    const topic = topicWords(previous[previous.length - 1]).filter(
      word => !have.has(word.toLowerCase()),
    );
    if (topic.length > 0) {
      base =
        `${base.replace(FOLLOW_UP_START, '').trim()} ${topic.join(' ')}`.trim();
      resolvedFollowUp = true;
    }
  }
  if (!base) {
    base = input.userText.trim();
  }
  const hints = dateHints(base, input.now);
  const first = clip([base, ...hints].join(' '));
  const queries = [first];
  if (max > 1) {
    for (const sub of subQueries(base, max - 1)) {
      const query = clip([sub, ...hints].join(' '));
      if (!queries.some(existing => normal(existing) === normal(query))) {
        queries.push(query);
      }
    }
  }
  return {queries: queries.slice(0, max), language, resolvedFollowUp};
}

/**
 * Clean a query the model wrote: quotes and operators it invented are
 * dropped, an empty query falls back to the user's words, and a stale year
 * ("… 2024" from training data when the user said "latest") is replaced.
 */
export function cleanModelQuery(
  query: unknown,
  context: {userText?: string; now: Date},
): string {
  let text = typeof query === 'string' ? query : '';
  text = text
    .replace(/^["'“”‘’`]+|["'“”‘’`]+$/g, '')
    .replace(/\b(?:site|intitle|inurl|filetype):\S+/gi, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  if (!text && context.userText) {
    return buildQueries({userText: context.userText, now: context.now})
      .queries[0];
  }
  const user = context.userText ?? '';
  const thisYear = context.now.getFullYear();
  if (
    user &&
    !/(?:19|20)\d{2}/.test(user) &&
    dateHints(user, context.now).length > 0
  ) {
    // The user asked for something current and named no year: a year from the
    // model's training data would pin the results to the past.
    text = text.replace(/\b(20\d{2})\b/g, year =>
      Number(year) < thisYear ? String(thisYear) : year,
    );
  }
  return clip(text);
}

// ---- sub-queries (port of AntiChat Mac SearchQuerySplit.swift) -------------

const QUESTION_WORDS = new Set([
  'what',
  'when',
  'which',
  'who',
  'whom',
  'whose',
  'where',
  'why',
  'how',
  'is',
  'are',
  'was',
  'were',
  'does',
  'do',
  'did',
  'will',
  'can',
  'has',
  'have',
]);
const JOINERS = new Set([
  'and',
  'or',
  'vs',
  'vs.',
  'versus',
  'und',
  'oder',
  'y',
  'et',
]);
const PAIR_CUES = new Set([
  'compare',
  'compared',
  'comparison',
  'vs',
  'vs.',
  'versus',
  'between',
  'both',
  'difference',
  'differences',
]);
const NOT_PLURAL = new Set([
  'is',
  'was',
  'has',
  'does',
  'us',
  'its',
  'this',
  'his',
  'news',
  'series',
  'status',
  'always',
  'less',
]);

const normal = (text: string): string =>
  text.toLowerCase().replace(/^[\s\p{P}]+|[\s\p{P}]+$/gu, '');
const trimPunctuation = (token: string): string =>
  token.replace(/^[\p{P}]+|[\p{P}]+$/gu, '');
const nameLike = (token: string): boolean =>
  /[\p{Lu}\d]/u.test(trimPunctuation(token));

function asksForMany(tokens: string[]): boolean {
  return tokens.some(token => {
    const bare = trimPunctuation(token);
    const word = bare.toLowerCase();
    if (!word) {
      return false;
    }
    if (PAIR_CUES.has(word)) {
      return true;
    }
    return (
      word === bare &&
      word.length > 3 &&
      word.endsWith('s') &&
      !word.endsWith('ss') &&
      !NOT_PLURAL.has(word)
    );
  });
}

/** Rule 1: "<name> and [the] <name>" → the message once per name. */
function splitNames(text: string): string[] {
  const tokens = text.split(' ').filter(Boolean);
  if (!asksForMany(tokens)) {
    return [];
  }
  for (let j = 1; j < tokens.length; j++) {
    if (!JOINERS.has(tokens[j].toLowerCase())) {
      continue;
    }
    let a = j - 1;
    if (!nameLike(tokens[a]) || tokens[a].endsWith(',')) {
      continue;
    }
    while (a > 0 && nameLike(tokens[a - 1]) && !tokens[a - 1].endsWith(',')) {
      a--;
    }
    let b = j + 1;
    if (
      b < tokens.length &&
      ['the', 'a', 'an'].includes(tokens[b].toLowerCase())
    ) {
      b++;
    }
    if (b >= tokens.length || !nameLike(tokens[b])) {
      continue;
    }
    let e = b;
    while (
      e + 1 < tokens.length &&
      nameLike(tokens[e + 1]) &&
      !tokens[e].endsWith(',') &&
      !tokens[e].endsWith('?')
    ) {
      e++;
    }
    const left = tokens.slice(0, a).join(' ');
    const right = tokens.slice(e + 1).join(' ');
    const first = tokens.slice(a, j).join(' ');
    const secondRaw = tokens.slice(b, e + 1).join(' ');
    const trail = /[\p{P}]+$/u.exec(secondRaw)?.[0] ?? '';
    const second = secondRaw.slice(0, secondRaw.length - trail.length);
    const join = (name: string) =>
      [left, name + trail, right].filter(Boolean).join(' ');
    return [join(first), join(second)];
  }
  return [];
}

/** Rule 2: clauses joined before a question word. */
function splitClauses(text: string): string[] {
  const tokens = text.split(' ').filter(Boolean);
  const parts: string[][] = [[]];
  tokens.forEach((token, index) => {
    const current = parts[parts.length - 1];
    const next = (tokens[index + 1] ?? '').toLowerCase();
    const last = current[current.length - 1];
    const endsClause = !!last && /[,;?]$/.test(last);
    if (
      token.toLowerCase() === 'and' &&
      QUESTION_WORDS.has(next) &&
      current.length
    ) {
      parts.push([]);
      return;
    }
    if (
      endsClause &&
      QUESTION_WORDS.has(token.toLowerCase()) &&
      current.length
    ) {
      parts.push([token]);
      return;
    }
    current.push(token);
  });
  const clauses = parts
    .map(part => part.join(' ').replace(/^[,;?. ]+|[,;?. ]+$/g, ''))
    .filter(clause => clause.split(' ').length >= 2);
  if (clauses.length < 2) {
    return [];
  }
  const topic = clauses[0]
    .split(' ')
    .map(trimPunctuation)
    .filter(word => word && !STOPWORDS.has(word.toLowerCase()))
    .join(' ');
  return clauses.map((clause, index) => {
    const refers = clause
      .split(' ')
      .some(word => BACK_REFERENCES.has(trimPunctuation(word).toLowerCase()));
    return index > 0 && refers && topic ? `${clause} ${topic}` : clause;
  });
}

/** Sub-queries of a message (not including it), at most `max`. */
export function subQueries(message: string, max: number): string[] {
  if (max <= 0) {
    return [];
  }
  const text = message.split(/\n+/).join(' ').trim();
  if (!text || text.length > MAX_QUERY_LENGTH) {
    return [];
  }
  let out = splitNames(text);
  if (out.length === 0) {
    out = splitClauses(text);
  }
  const seen = new Set([normal(text)]);
  const kept: string[] = [];
  for (const query of out) {
    const key = normal(query);
    if (!query || seen.has(key)) {
      continue;
    }
    seen.add(key);
    kept.push(query.replace(/[?.!]+$/, ''));
    if (kept.length === max) {
      break;
    }
  }
  return kept;
}
