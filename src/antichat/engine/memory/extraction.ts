/**
 * Finding lasting facts about the user in a finished chat (H2).
 *
 * One short side generation on the chat model: the user's messages go in,
 * a JSON list of at most five facts comes out under a schema grammar. Code
 * then screens the list (`screenFacts`): the privacy rules do not depend on
 * the model following them.
 *
 * The prompt is ours. It grew from mem0's fact-extraction prompt (Apache-2.0,
 * mem0/configs/prompts.py) and the AntiChat Mac capture prompt, cut down for
 * 2B-class models and measured against both alternatives in
 * docs/antichat/m9-eval.md.
 */
import type {CompletionEngine} from '../../../utils/completionTypes';
import type {ModelFamily} from '../prompt/modelFamily';
import type {ChatMessage} from '../prompt/types';
import {runUtilityCompletion} from '../prompt/utility';
import {clip, coverage, fold, normalizeFact, slotOf, stemSet} from './text';
import type {MemoryKind, SensitiveCategory} from './types';

export const MAX_FACTS_PER_PASS = 5;
/** User turns read per pass, newest last. */
export const MAX_TURNS_PER_PASS = 10;
const MAX_TURN_CHARS = 500;
const MAX_INPUT_CHARS = 3200;
const MAX_LINE_CHARS = 300;

/** The rules every style shares. */
export const EXTRACTION_RULES = `You maintain the long-term memory of a personal assistant. Read the messages a user wrote in one chat and list what is worth remembering about the user in future chats.

Save lasting facts the user states about themselves: name, age, home, job or studies, family, partner, pets, lasting likes and dislikes, diet, hobbies, ongoing projects, long-term goals, and how they want the assistant to answer.
Do not save: what the user asks for in this chat (requests, questions, tasks), things that only matter today or this week, text the user wants written, translated or corrected, facts that are only about other people, or anything you would have to guess.
If the user corrects themselves, save only the corrected fact.
Set "private" to true for health conditions, medication, sexuality, religion, political views, money, addresses, passwords and ID numbers; otherwise false.
"type" is "profile" for who the user is, "preference" for what they like or how they want answers, "context" for current projects, plans and goals.

One fact per item, as a short sentence starting with "User", in the language the user writes in. At most ${MAX_FACTS_PER_PASS} items. Most chats contain nothing worth saving: then return {"memories": []}.`;

interface Example {
  known?: string[];
  turns: string[];
  memories: Array<{text: string; type: MemoryKind; private: boolean}>;
}

/**
 * Worked examples. They cover the mistakes the rules alone did not stop on
 * Gemma 4 E2B: saving the request, saving text that is not about the user,
 * keeping both sides of a correction, and missing a change to a saved fact.
 */
export const EXTRACTION_EXAMPLES: Example[] = [
  {
    turns: ['Write a polite email to my boss asking for Friday off.'],
    memories: [],
  },
  {
    turns: [
      'My name is Kenji and I teach history at a high school. What is a good way to explain the French Revolution to teenagers?',
    ],
    memories: [
      {text: "User's name is Kenji.", type: 'profile', private: false},
      {
        text: 'User teaches history at a high school.',
        type: 'profile',
        private: false,
      },
    ],
  },
  {
    turns: [
      'Fix the grammar: "I has two brothers and I lives in Rome since 2019."',
    ],
    memories: [],
  },
  {
    turns: [
      'Which laptop should I get for video editing? I am a wedding photographer and I always travel with a 13-inch bag.',
    ],
    memories: [
      {
        text: 'User is a wedding photographer.',
        type: 'profile',
        private: false,
      },
    ],
  },
  {
    turns: [
      'I work four days a week, so I have Fridays for my pottery.',
      'Sorry, three days a week since January. What should I make first on the wheel?',
    ],
    memories: [
      {text: 'User works three days a week.', type: 'profile', private: false},
      {text: 'User does pottery.', type: 'preference', private: false},
    ],
  },
  {
    turns: [
      'I have asthma and I love trail running. Which shoes should I buy for a race on Sunday?',
    ],
    memories: [
      {text: 'User has asthma.', type: 'profile', private: true},
      {text: 'User loves trail running.', type: 'preference', private: false},
    ],
  },
  {
    known: ['User plays the guitar.', 'User has a sister.'],
    turns: [
      'I sold my guitar and gave up playing, no time. My sister Ines says I should try the piano. Any beginner pieces?',
    ],
    memories: [
      {
        text: 'User no longer plays the guitar.',
        type: 'preference',
        private: false,
      },
      {text: "User's sister is called Ines.", type: 'profile', private: false},
    ],
  },
];

/**
 * How the prompt is laid out.
 *  - `examples`: rules plus worked examples in the system prompt. Best on
 *    Gemma 4 E2B (P 0.82 → 0.94, R 0.78 → 0.94 against rules only).
 *  - `rules`: the rules alone. LFM3 1.7B copies example facts into its
 *    answer ("User does pottery" for a chat about a dog), so it gets none.
 * Numbers: docs/antichat/m9-eval.md §4.
 */
export type ExtractionStyle = 'examples' | 'rules';

export function extractionStyleFor(family?: ModelFamily): ExtractionStyle {
  return family === 'gemma4' ? 'examples' : 'rules';
}

function renderInput(turns: string[], known: string[] = []): string {
  const list = turns.map((turn, index) => `${index + 1}. ${turn}`).join('\n');
  const saved = known.length
    ? `Already saved:\n${known.map(text => `- ${text}`).join('\n')}\n`
    : '';
  return `${saved}User messages:\n${list}`;
}

const renderedExamples = EXTRACTION_EXAMPLES.map(
  example =>
    `${renderInput(example.turns, example.known)}\n${JSON.stringify({
      memories: example.memories,
    })}`,
).join('\n\n');

const KNOWN_RULE =
  'Facts listed under "Already saved" are known: do not repeat them. If the user says one of them has changed or is no longer true, save the new state.';

export const EXTRACTION_SYSTEM_PROMPT = `${EXTRACTION_RULES}\n${KNOWN_RULE}\n\nExamples (other users; never copy facts from them)\n\n${renderedExamples}`;

export function extractionSystemPrompt(style: ExtractionStyle): string {
  return style === 'examples' ? EXTRACTION_SYSTEM_PROMPT : EXTRACTION_RULES;
}

export const EXTRACTION_SCHEMA = {
  type: 'object',
  properties: {
    memories: {
      type: 'array',
      maxItems: MAX_FACTS_PER_PASS,
      items: {
        type: 'object',
        properties: {
          text: {type: 'string', maxLength: 160},
          type: {type: 'string', enum: ['profile', 'preference', 'context']},
          private: {type: 'boolean'},
        },
        required: ['text', 'type', 'private'],
        additionalProperties: false,
      },
    },
  },
  required: ['memories'],
  additionalProperties: false,
};

export interface ExtractedFact {
  text: string;
  kind: MemoryKind;
  /** The private category (`'other'`: flagged private, no category). */
  sensitive: SensitiveCategory | null;
  /** The user asked for this to be remembered (set by `screenFacts`). */
  explicit: boolean;
}

// ---- explicit requests ("remember that …")

/**
 * Requests to remember and standing instructions, in the six languages the
 * app ships in. Matched on folded text. List from AntiChat Mac's capture
 * gate (`MemoryCaptureGate.table[*].anywhere`).
 */
const REMEMBER_CUES = [
  // en
  'remember that',
  'remember this',
  'remember my',
  'remember i',
  'please remember',
  'can you remember',
  'keep in mind',
  "don't forget",
  'dont forget',
  'do not forget',
  'for future reference',
  'from now on',
  'going forward',
  'save this',
  'save that',
  'note that i',
  'make a note',
  'add to memory',
  'add to your memory',
  'save to memory',
  // nl
  'vanaf nu',
  'voortaan',
  'in het vervolg',
  'onthoud',
  'vergeet niet',
  'houd er rekening mee',
  'hou er rekening mee',
  // de
  'ab jetzt',
  'ab sofort',
  'von nun an',
  'kunftig',
  'merk dir',
  'merke dir',
  'denk daran',
  'denke daran',
  'vergiss nicht',
  // fr
  'desormais',
  'dorenavant',
  'a partir de maintenant',
  'souviens-toi',
  'souviens toi',
  'souvenez-vous',
  'rappelle-toi',
  'rappelle toi',
  'retiens que',
  "n'oublie pas",
  "n'oubliez pas",
  'garde en tete',
  // es
  'a partir de ahora',
  'de ahora en adelante',
  'recuerda que',
  'recuerde que',
  'recuerda esto',
  'acuerdate',
  'no olvides',
  'ten en cuenta',
  // pt
  'a partir de agora',
  'de agora em diante',
  'lembre-se',
  'lembre se',
  'lembra-te',
  'lembre que',
  'nao esqueca',
  'tenha em mente',
];

const STANDING_CUES = [
  'always answer',
  'always reply',
  'always respond',
  'always use',
  'please always',
  'never use',
  'please never',
  'stop using',
  'antworte immer',
  'bitte immer',
  'verwende immer',
  'reponds toujours',
  'responde siempre',
  'responda sempre',
  'antwoord altijd',
];

const FORGET_CUES = [
  'forget that',
  'forget what i',
  'forget about my',
  'forget my',
  "don't remember",
  'do not remember',
  'delete that memory',
  'remove that from memory',
  'remove that from your memory',
  'vergiss dass',
  'vergiss das',
  'oublie que',
  'olvida que',
  'esqueca que',
  'vergeet dat',
];

const hasCue = (text: string, cues: string[]): boolean => {
  const folded = fold(text).replace(/[’‘`]/g, "'");
  return cues.some(cue => folded.includes(cue));
};

/** Did the user ask for something to be remembered in this message? */
export function hasRememberCue(text: string): boolean {
  return hasCue(text, REMEMBER_CUES);
}

/** A remember request or a standing instruction ("always answer in …"). */
export function hasMemoryCue(text: string): boolean {
  return hasCue(text, REMEMBER_CUES) || hasCue(text, STANDING_CUES);
}

/** Did the user ask to forget something? */
export function hasForgetCue(text: string): boolean {
  return hasCue(text, FORGET_CUES);
}

// ---- privacy backstop

/**
 * Words that mark a fact as private whatever the model says. Deliberately
 * narrow: it has to catch the clear cases without touching ordinary facts
 * (diet and allergies are not treated as private). English first; the
 * other shipped languages follow below.
 */
const SENSITIVE_PATTERNS: Array<{
  category: SensitiveCategory;
  pattern: RegExp;
}> = [
  {
    category: 'health',
    pattern:
      /\b(?:diagnos\w*|depress\w*|anxiety disorder|bipolar|adhd|autis\w*|diabet\w*|cancer|chemo\w*|hiv|epilep\w*|antidepress\w*|medication|prescri\w*|therap(?:y|ist)|psychiatr\w*|pregnan\w*|miscarriage|std|ibs|crohn\w*|asthma|insulin|sertraline|prozac|xanax|ozempic|migraines?|eating disorder|rehab|sober|alcoholi\w*)\b/,
  },
  {
    category: 'sexuality',
    pattern:
      /\b(?:gay|lesbian|bisexual|queer|homosexual|asexual|transgender|non-?binary|sexual orientation|coming out|came out)\b/,
  },
  {
    category: 'religion',
    pattern:
      /\b(?:muslim|christian|catholic|protestant|jewish|hindu|buddhist|atheist|agnostic|mormon|sikh|goes to (?:church|mosque|synagogue|temple)|religio\w*|prays?)\b/,
  },
  {
    category: 'politics',
    pattern:
      /\b(?:votes?|voted|voter|democrat|republican|labour party|tory|conservatives?|liberal party|libertarian|socialist|communist|left-wing|right-wing|afd|cdu|spd|politic\w*|party member|member of the \w+ party)\b/,
  },
  {
    category: 'finances',
    pattern:
      /\b(?:salary|earns?|income|net worth|debts?|owes?|mortgage|loan|bankrupt\w*|savings? of|credit score|iban|bank account|(?:[$€£]|usd|eur)\s?\d[\d.,]*k?)\b/,
  },
  {
    category: 'identity',
    pattern:
      /\b(?:password|passcode|pin (?:code )?is|social security|ssn|passport (?:number|no)|credit card|card number|license number|home address is|lives at \d+)\b/,
  },
];

/**
 * The same categories in German, French, Spanish, Portuguese and Dutch
 * (folded: no accents). Shorter than the English list: the clear cases.
 */
const SENSITIVE_PATTERNS_OTHER: Array<{
  category: SensitiveCategory;
  pattern: RegExp;
}> = [
  {
    category: 'health',
    pattern:
      /\b(?:diagnos\w*|depressi\w*|depresi\w*|krebs|cancer|kanker|diabet\w*|epileps\w*|epileptic\w*|schwanger\w*|enceinte|embarazada|gravida|zwanger|medikament\w*|medicament\w*|medicijn\w*|therapi\w*|terapia|psychiat\w*|psiquiat\w*|asma|asthme|hiv|vih|sida|krankheit|maladie|enfermedad|doenca|ziekte)\b/,
  },
  {
    category: 'sexuality',
    pattern:
      /\b(?:schwul|lesbisch|lesbienne|lesbiana|lesbica|homosexuel\w*|homosexuell\w*|homosexual|homoseksue\w*|bisexuel\w*|bisexuell\w*|bisexual|biseksue\w*|transgender|trans(?:sexuel|exual)\w*|geoutet)\b/,
  },
  {
    category: 'religion',
    pattern:
      /\b(?:muslim\w*|moslem\w*|musulman\w*|muculman\w*|moslim\w*|christ(?:in)?|chretien\w*|cristian\w*|cristao|katholi\w*|catholique|catolic\w*|evangelisch|protestant\w*|jud(?:e|in|io|ia|eu)|juif|juive|joods|hindu\w*|buddhist\w*|bouddhiste|budista|atheist\w*|athee|ateo|atea|ateu|religi\w*|glaubig|croyant\w*|creyente)\b/,
  },
  {
    category: 'politics',
    pattern:
      /\b(?:wahle|wahlt|gewahlt|votes?|voto|vota|stem(?:t|de)? op|partei\w*|parti politique|partido politico|partij|politi\w*|sozialist\w*|socialist\w*|kommunist\w*|communist\w*|comunista|konservativ\w*|conservateur\w*|conservador\w*|linksradikal|rechtsradikal)\b/,
  },
  {
    category: 'finances',
    pattern:
      /\b(?:gehalt|verdiene?|verdient|einkommen|schulden|kredit|hypothek|salaire|revenus?|dettes?|pret immobilier|hypotheque|salario|sueldo|ingresos|deudas?|hipoteca|prestamo|ordenado|renda|dividas?|emprestimo|salaris|inkomen|hypotheek|lening)\b/,
  },
  {
    category: 'identity',
    pattern:
      /\b(?:passwort|kennwort|mot de passe|contrasena|senha|wachtwoord|ausweisnummer|reisepass\w*|passeport|pasaporte|passaporte|paspoort|kreditkarte\w*|carte bancaire|tarjeta de credito|cartao de credito|creditcard\w*)\b/,
  },
];

export function detectSensitive(text: string): SensitiveCategory | null {
  const folded = fold(text);
  for (const patterns of [SENSITIVE_PATTERNS, SENSITIVE_PATTERNS_OTHER]) {
    for (const {category, pattern} of patterns) {
      if (pattern.test(folded)) {
        return category;
      }
    }
  }
  return null;
}

// ---- input

/** Six or more words inside quotation marks. */
const QUOTED_PASSAGE =
  /["“„«](?:[^"“”„«»\n]*\s){5,}[^"“”„«»\n]*["”»]|'(?:[^'\n]*\s){5,}[^'\n]*'(?!\w)/g;

/**
 * The user's own words from a chat, ready for the prompt: quoted lines,
 * code blocks and pasted walls of text are dropped, each turn is clipped,
 * and the newest turns win when the whole is too long.
 */
export function prepareUserTurns(turns: string[]): string[] {
  const cleaned: string[] = [];
  for (const turn of turns) {
    const withoutCode = turn
      .replace(/```[\s\S]*?(?:```|$)/g, ' ')
      // A quoted passage is text to work on, not the user talking.
      .replace(QUOTED_PASSAGE, ' ');
    const lines = withoutCode
      .split('\n')
      .map(line => line.trim())
      .filter(
        line =>
          line.length > 0 &&
          !line.startsWith('>') &&
          line.length <= MAX_LINE_CHARS,
      );
    const text = clip(lines.join(' '), MAX_TURN_CHARS);
    if (text) {
      cleaned.push(text);
    }
  }
  const kept = cleaned.slice(-MAX_TURNS_PER_PASS);
  let total = kept.reduce((sum, turn) => sum + turn.length, 0);
  while (kept.length > 1 && total > MAX_INPUT_CHARS) {
    total -= kept.shift()!.length;
  }
  return kept;
}

export function buildExtractionMessages(
  turns: string[],
  known: string[] = [],
  style: ExtractionStyle = 'examples',
): ChatMessage[] {
  // Without the worked example, "Already saved" makes LFM3 return nothing
  // at all for a chat that changes a saved fact; it gets the plain list.
  const shown = style === 'examples' ? known : [];
  return [
    {role: 'system', content: extractionSystemPrompt(style)},
    {role: 'user', content: renderInput(turns, shown)},
  ];
}

// ---- output

const KIND_ALIASES: Record<string, MemoryKind> = {
  profile: 'profile',
  preference: 'preference',
  context: 'context',
};
const CATEGORIES: SensitiveCategory[] = [
  'health',
  'sexuality',
  'religion',
  'politics',
  'finances',
  'identity',
];

/** The first JSON value in `raw`, or null. Tolerates text around it. */
export function parseJsonLoose(raw: string): unknown {
  const text = raw.trim();
  try {
    return JSON.parse(text);
  } catch {
    // Fall through to the bracket scan.
  }
  const starts = [text.indexOf('{'), text.indexOf('[')].filter(i => i >= 0);
  if (starts.length === 0) {
    return null;
  }
  const start = Math.min(...starts);
  const close = text[start] === '{' ? '}' : ']';
  for (let end = text.lastIndexOf(close); end > start; ) {
    try {
      return JSON.parse(text.slice(start, end + 1));
    } catch {
      end = text.lastIndexOf(close, end - 1);
    }
  }
  return null;
}

/**
 * Reads the model's answer. Accepts our shape (`{"memories": [{…}]}`) and
 * the plain list mem0's prompt returns (`{"facts": ["…"]}`).
 */
export function parseExtraction(raw: string): ExtractedFact[] {
  const parsed = parseJsonLoose(raw) as any;
  const list: unknown[] = Array.isArray(parsed)
    ? parsed
    : Array.isArray(parsed?.memories)
      ? parsed.memories
      : Array.isArray(parsed?.facts)
        ? parsed.facts
        : [];
  const facts: ExtractedFact[] = [];
  for (const entry of list) {
    if (typeof entry === 'string') {
      if (entry.trim()) {
        facts.push({
          text: entry.trim(),
          kind: 'context',
          sensitive: null,
          explicit: false,
        });
      }
      continue;
    }
    if (!entry || typeof entry !== 'object') {
      continue;
    }
    const item = entry as Record<string, unknown>;
    const text =
      typeof item.text === 'string'
        ? item.text
        : typeof item.fact === 'string'
          ? item.fact
          : '';
    if (!text.trim()) {
      continue;
    }
    const category = String(
      item.sensitive ?? item.sensitive_category ?? 'none',
    );
    facts.push({
      text: text.trim(),
      kind: KIND_ALIASES[String(item.type ?? item.kind)] ?? 'context',
      sensitive: CATEGORIES.includes(category as SensitiveCategory)
        ? (category as SensitiveCategory)
        : item.private === true
          ? 'other'
          : null,
      explicit: false,
    });
  }
  return facts;
}

const exampleFacts = EXTRACTION_EXAMPLES.flatMap(example =>
  example.memories.map(memory => stemSet(normalizeFact(memory.text))),
);

/**
 * True when a fact matches one of the prompt's example facts and the
 * user's messages do not back it. Small models copy examples.
 */
function isExampleLeak(norm: string, turns: string[]): boolean {
  const stems = stemSet(norm);
  if (!exampleFacts.some(example => coverage(example, stems) >= 0.99)) {
    return false;
  }
  const said = stemSet(turns.join(' '));
  return coverage(stems, said) < 0.5;
}

export interface ScreenOptions {
  /** The user's messages the facts came from. */
  turns: string[];
  /** Keep private facts the user did not ask to save (a setting; off). */
  includeSensitive?: boolean;
  maxFacts?: number;
}

/** Sentence starts that show the model wrote about the chat, not the user. */
const NOT_A_FACT =
  /^(?:the )?(?:assistant|ai|chat|conversation|model)\b|^(?:user )?(?:asked|asks|is asking|said|wrote|wants to know|wanted to know|requested|requests|is requesting|needs help|needed help)\b/;

/** "User wants a polite email…": a request of this chat, not a fact. */
const REQUEST =
  /^user (?:wants|needs|would like|is looking for|is seeking|is asking for|is interested in getting)\s+(?:a|an|some|the|help|advice|ideas|tips|suggestions|recommendations|information|feedback|\d+|two|three|four|five|to (?:know|find|get|buy|write|translate|choose|compare|see|hear|ask|understand|fix|make|plan|order|have))\b/;

/** "User needs dinner ideas for the week." */
const REQUEST_FOR =
  /^user (?:wants|needs|would like|is looking for|is seeking|is asking for)\b(?: [\w-]+){0,4} (?:ideas?|tips|suggestions|recommendations|advice|help|recipes?|plan|routine|list|email|letter|story|summary|translation|explanation|gift|phrases|pieces)\b/;

/** Passing states: never a lasting fact. */
const PASSING_STATE =
  /\b(?:is|was|feels|feeling|got|slept)\b[^.]*\b(?:tired|bored|sleepy|exhausted|hungry|hours of sleep|a headache|hungover)\b/;

const WEEKDAY =
  '(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|montag|dienstag|mittwoch|donnerstag|freitag|samstag|sonntag|lunes|martes|miercoles|jueves|viernes|sabado|domingo)';
/** Things that will not be true next month. */
const TRANSIENT = new RegExp(
  `\\b(?:today|tonight|tomorrow|yesterday|right now|currently|at the moment|this (?:week|weekend|morning|afternoon|evening)|next (?:week|weekend|${WEEKDAY})|(?:on|by|this|until) ${WEEKDAY}|last night|heute|diese woche|nachste woche|hoy|esta semana|aujourd hui|demain|cette semaine|vandaag|deze week)\\b`,
);

/**
 * The rules that must hold whatever the model answers:
 *  - a private fact is kept only when the user asked to remember it (a
 *    remember cue in a message of theirs that is about the same thing), or
 *    the setting allows it;
 *  - requests of this chat, dated one-offs, questions, facts about the
 *    chat itself and repeats go.
 */
/** Should this clause of a fact go? `sentence` starts with "user ". */
function isNoise(sentence: string): boolean {
  if (
    NOT_A_FACT.test(sentence) ||
    REQUEST.test(sentence) ||
    REQUEST_FOR.test(sentence) ||
    PASSING_STATE.test(sentence)
  ) {
    return true;
  }
  // A dated one-off ("has an exam on Friday") goes; a lasting fact that
  // happens to carry a date ("starts as an analyst on Monday") stays.
  return TRANSIENT.test(sentence) && !slotOf(sentence);
}

const CLAUSE_BREAK = /(\s+(?:and|but|who|which|while)\s+|[,;]\s+)/;

/**
 * Small models pack a request and a fact into one sentence ("User wants
 * help with a workout and has a bad knee"). The noisy clauses are cut out
 * and the rest is kept; null when nothing is left.
 */
export function trimFact(text: string): string | null {
  const whole = fold(text)
    .replace(/[’']/g, ' ')
    .replace(/^(?:the )?user\s+/, 'user ');
  const parts = text.split(CLAUSE_BREAK);
  if (parts.length === 1) {
    return isNoise(whole) ? null : text;
  }
  const keep: number[] = [];
  for (let i = 0; i < parts.length; i += 2) {
    const clause = fold(parts[i]).replace(/[’']/g, ' ');
    const sentence =
      i === 0
        ? clause.replace(/^(?:the )?user\s+/, 'user ')
        : `user ${clause.replace(/^(?:also|then|now|he|she|they)\s+/, '')}`;
    if (!isNoise(sentence)) {
      keep.push(i);
    }
  }
  if (keep.length === (parts.length + 1) / 2) {
    return text;
  }
  // Whatever followed a dropped opening ("…, so avoid jumping") only makes
  // sense with a statement in front of it.
  // …and a leftover fragment ("Japanese") is not a statement at all.
  const solid = keep.filter(
    i =>
      !/^(?:so|because|since|as|to|for)\b/i.test(parts[i].trim()) &&
      (i === 0 || parts[i].trim().split(/\s+/).length >= 3),
  );
  if (solid.length === 0) {
    return null;
  }
  let out = '';
  for (const i of keep) {
    if (i < solid[0]) {
      continue;
    }
    if (!out) {
      const clause = parts[i].trim().replace(/^(?:also|then|now)\s+/i, '');
      out = i === 0 ? clause : `User ${clause}`;
    } else {
      out += parts[i - 1] + parts[i];
    }
  }
  return out.replace(/[\s,;:.]+$/, '') + '.';
}

export function screenFacts(
  facts: ExtractedFact[],
  options: ScreenOptions,
): ExtractedFact[] {
  const cueTurns = options.turns.filter(hasRememberCue).map(stemSet);
  const standing = options.turns.some(hasMemoryCue);
  const seen = new Set<string>();
  const kept: ExtractedFact[] = [];
  for (const fact of facts) {
    const cleaned = clip(fact.text.replace(/^[-*\d.\s]+/, ''), 200);
    if (cleaned.endsWith('?')) {
      continue;
    }
    const text = trimFact(cleaned);
    if (!text) {
      continue;
    }
    const norm = normalizeFact(text);
    if (norm.length < 3 || seen.has(norm)) {
      continue;
    }
    // A fact lifted from the prompt's own examples.
    if (isExampleLeak(norm, options.turns)) {
      continue;
    }
    // "Asked" needs the user's own words: a message with a remember cue
    // that talks about the same thing as the fact.
    const stems = stemSet(norm);
    const overlap = cueTurns.reduce(
      (best, turn) => Math.max(best, coverage(stems, turn)),
      0,
    );
    const explicit = overlap >= 0.5;
    const sensitive = detectSensitive(text) ?? fact.sensitive;
    if (sensitive && !explicit && !options.includeSensitive) {
      continue;
    }
    seen.add(norm);
    kept.push({
      text,
      kind:
        fact.kind === 'context' &&
        standing &&
        /\b(?:answer|repl|respon)/.test(norm)
          ? 'preference'
          : fact.kind,
      sensitive,
      explicit,
    });
    if (kept.length >= (options.maxFacts ?? MAX_FACTS_PER_PASS)) {
      break;
    }
  }
  return kept;
}

export interface ExtractionRequest {
  engine: CompletionEngine;
  family?: ModelFamily;
  /** The user's messages of one chat, oldest first. */
  turns: string[];
  /** Saved memories related to the chat (so changes to them are seen). */
  known?: string[];
  /** Prompt layout; defaults to what was measured best for the family. */
  style?: ExtractionStyle;
  includeSensitive?: boolean;
  signal?: AbortSignal;
  timeoutMs?: number;
}

export interface ExtractionResult {
  /** False when the model call failed, timed out or was aborted. */
  ok: boolean;
  facts: ExtractedFact[];
  /** What the model returned before screening (for the evaluation). */
  raw: ExtractedFact[];
}

/** One extraction call. Never throws. */
export async function extractFacts(
  request: ExtractionRequest,
): Promise<ExtractionResult> {
  const turns = prepareUserTurns(request.turns);
  if (turns.length === 0) {
    return {ok: true, facts: [], raw: []};
  }
  const style = request.style ?? extractionStyleFor(request.family);
  const result = await runUtilityCompletion({
    engine: request.engine,
    family: request.family,
    messages: buildExtractionMessages(turns, request.known, style),
    maxTokens: 320,
    temperature: 0,
    jsonSchema: {name: 'memories', schema: EXTRACTION_SCHEMA},
    timeoutMs: request.timeoutMs ?? 30000,
    signal: request.signal,
  });
  if (!result) {
    return {ok: false, facts: [], raw: []};
  }
  const raw = parseExtraction(result.text);
  // LFM3 flags ordinary facts as private ("is a software developer"); its
  // flag is ignored and the keyword check alone decides.
  const trusted =
    style === 'examples' ? raw : raw.map(fact => ({...fact, sensitive: null}));
  return {
    ok: true,
    raw,
    facts: screenFacts(trusted, {
      turns,
      includeSensitive: request.includeSensitive,
    }),
  };
}
