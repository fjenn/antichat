/**
 * The search decision ("should I search?") for small models: rules first,
 * no model call. Design: AntiChat Mac's `FreshnessDetector` + conversational
 * abstain gate, plus the forced direct search the Mac uses on its small
 * tiers (the harness searches with the user's own words instead of waiting
 * for the model to decide and write a query).
 *
 *   force  the turn needs current information → the harness runs web_search
 *          itself before the first model step (when the model's caps allow)
 *   none   the turn plainly needs no search (greeting, maths, translation,
 *          drafting) → tools are withheld for the turn
 *   auto   everything else → the model decides with `tool_choice: auto`
 *
 * An optional one-word model pre-pass (`classifySearchNeed`) exists for the
 * `auto` band. It is off by default: measured on fresh-vs-stable-200 it is
 * precise on Qwen3.5-4B and useless on LFM3-1.7B, which says "search" to
 * everything (docs/antichat/m8-eval.md).
 */
import type {CompletionEngine} from '../../../utils/completionTypes';
import type {ChatMessage} from '../prompt/types';
import {EXTRA_TERMS, FRESH_TERMS, STABLE_GUARDS} from './freshTerms';

export type SearchDecision = 'force' | 'auto' | 'none';

export type SearchReason =
  | 'chip'
  | 'explicit'
  | 'fresh_term'
  | 'later_date'
  | 'conversational'
  | 'stable_task'
  | 'has_url'
  | 'personal'
  | 'default';

export interface SearchVerdict {
  decision: SearchDecision;
  reason: SearchReason;
  /** No tool of any kind is useful (greeting, thanks): withhold them all. */
  abstainAll?: boolean;
}

export interface DecisionInput {
  userText: string;
  /**
   * Another offered tool is named by the message ("email", "calendar",
   * "timer", "weather"): the model picks the tool, the harness does not
   * search first.
   */
  otherToolMatches?: boolean;
  /** The Search chip is on for this message. */
  searchChip?: boolean;
  /** "YYYY-MM"; a later year in the question forces a search. */
  knowledgeCutoff?: string;
  /** The message carries an attachment the question is about. */
  hasAttachment?: boolean;
}

const bounded = (fragment: string): RegExp =>
  new RegExp(`(?<![\\p{L}\\p{N}])(?:${fragment})(?![\\p{L}\\p{N}])`, 'iu');

const compile = (fragments: string[]): RegExp[] =>
  fragments.flatMap(fragment => {
    try {
      return [bounded(fragment)];
    } catch {
      return [];
    }
  });

const TERMS = compile([...Object.values(FRESH_TERMS).flat(), ...EXTRA_TERMS]);
const GUARDS = compile(STABLE_GUARDS);

const URL =
  /\bhttps?:\/\/\S+|(?<![@\w.-])(?:www\.)?[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:com|org|net|io|dev|ai|app|co|de|uk|fr|es|it|nl|eu|edu|gov)(?![\w@-])(?:\/\S*)?/i;

/** The user asks in so many words for a web search. */
const EXPLICIT =
  /\b(?:search (?:the )?(?:web|internet|online)|search (?:for|up)|look (?:it |this |that )?up|google (?:it|this|that|for)?|check online|find (?:me )?(?:the )?latest|such(?:e)? (?:im (?:internet|netz|web)|nach)|im internet (?:nach)?such|busca(?:r)? en (?:internet|la web)|cherche(?:r)? sur (?:internet|le web)|zoek (?:op|online)|pesquis[ae]r? na (?:internet|web))\b/i;

/** Greetings, thanks, acknowledgements, farewells: nothing to look up. */
const CONVERSATIONAL =
  /^(?:(?:hi|hey|hello|yo|hiya|howdy|good (?:morning|afternoon|evening|night)|thanks?(?: you)?(?: so much| a lot)?|thx|ty|cheers|ok(?:ay)?|k|cool|great|nice|perfect|awesome|got it|understood|sure|yes|no|yep|nope|bye|goodbye|see you|good ?night|lol|haha|hallo|hi|moin|servus|danke(?: schön| dir)?|tschüss|hola|gracias|adi[oó]s|bonjour|salut|merci|ciao|grazie|ol[aá]|obrigad[oa]|dank(?: je| u)?(?: wel)?|doei)(?:[\s,.!?]+|$))+(?:(?:that'?s|that is|this is) (?:all|it|great|perfect|helpful)(?: i needed)?|how(?:'s| is) it going|how are you(?: doing)?|what'?s up|wie geht'?s|there|again|everyone|all i needed|for (?:that|the help|your help)|very much|a lot|man|mate)?[\s.!?]*$/i;

/** Tasks the model does from its own head. */
const STABLE_TASKS: RegExp[] = [
  // arithmetic
  /^(?:what(?:'s| is)|calculate|compute|how much is)?\s*[-+]?\d[\d.,]*\s*(?:[-+*/x×÷^%]|times|plus|minus|divided by|multiplied by|to the power of|percent of|% of)\s*[-+]?\d[\d.,\s%]*(?:[-+*/x×÷^]\s*\d[\d.,]*\s*)*[=?.!\s]*$/i,
  // translation
  /^(?:please )?(?:translate|übersetze?|traduce|traduis|traduza|vertaal)\b/i,
  /\b(?:how do (?:you|i) say|what(?:'s| is) .{1,60} in (?:spanish|french|german|italian|portuguese|dutch|english|japanese|chinese|korean|russian|arabic|latin))\b/i,
  // drafting and creative writing
  /^(?:please )?(?:write|draft|compose|rewrite|rephrase|paraphrase|proofread|summari[sz]e this|shorten|expand|schreib|verfasse|formuliere|escribe|redacta|écris|rédige|scrivi|escreva|schrijf)\b/i,
  // code
  /^(?:please )?(?:write|fix|debug|refactor|explain) (?:a |an |the |this |my )?(?:python|javascript|typescript|swift|kotlin|java|c\+\+|rust|go|sql|bash|regex|function|script|code|query|class|loop)\b/i,
  // definitions and explanations of timeless things
  /^(?:explain|define|describe)\b(?!.*\b(?:news|latest|today|current|recent)\b)/i,
  // brainstorming
  /^(?:give me|suggest|brainstorm|come up with) (?:\d+ |some |a few )?(?:ideas|names|titles|slogans|jokes|puns)\b/i,
  // rolling a die, telling a joke
  /^(?:tell me a (?:joke|story|riddle)|roll a di(?:c)?e|flip a coin)\b/i,
];

/** The question is about the user's own data, which lives in other tools. */
const PERSONAL =
  /\b(?:my|mein(?:e[mnrs]?)?|mis?|mon|ma|mes|mijn|meus?|minhas?)\s+(?:\w+\s+){0,2}(?:calendar|schedule|agenda|appointments?|meetings?|events?|e-?mails?|mails?|inbox|mailbox|messages?|contacts?|notes?|reminders?|files?|documents?|photos?|tasks?|to-?dos?|bookings?|reservations?|orders?|flights?|kalender|termine?|postfach|nachrichten|notizen|calendario|correo|citas?|courriels?|rendez-vous|notities|afspraak)\b|\b(?:am i|do i have|have i got|did i (?:get|receive))\b.{0,60}\b(?:free|busy|meeting|appointment|anything|something|events?|mails?|emails?)\b|\b[\w.+-]+@[\w-]+\.[\w.-]+\b/i;

const YEAR = /(?<!\d)(?:19|20)\d{2}(?!\d)/g;

/** A year after the cutoff's year (or the cutoff's year, cutoff before December). */
export function mentionsLaterDate(text: string, cutoff: string): boolean {
  const [yearText, monthText] = cutoff.split('-');
  const cutoffYear = Number(yearText);
  const cutoffMonth = monthText ? Number(monthText) : 12;
  if (!cutoffYear) {
    return false;
  }
  for (const match of text.matchAll(YEAR)) {
    const year = Number(match[0]);
    if (year > cutoffYear || (year === cutoffYear && cutoffMonth < 12)) {
      return true;
    }
  }
  return false;
}

export function isConversational(text: string): boolean {
  const trimmed = text.trim();
  return trimmed.length <= 60 && CONVERSATIONAL.test(trimmed);
}

export function hasFreshTerm(text: string): boolean {
  return TERMS.some(term => term.test(text));
}

export function hasStableGuard(text: string): boolean {
  return GUARDS.some(guard => guard.test(text));
}

/** The rule gate. Pure and synchronous: costs nothing per turn. */
export function decideSearch(input: DecisionInput): SearchVerdict {
  const text = input.userText.trim();
  if (input.searchChip && text) {
    return {decision: 'force', reason: 'chip'};
  }
  if (!text || isConversational(text)) {
    return {decision: 'none', reason: 'conversational', abstainAll: true};
  }
  if (URL.test(text)) {
    // A page the user names is read, not searched for.
    return {decision: 'auto', reason: 'has_url'};
  }
  const personal = PERSONAL.test(text);
  if (EXPLICIT.test(text) && !personal) {
    return {decision: 'force', reason: 'explicit'};
  }
  const stableTask = STABLE_TASKS.some(pattern => pattern.test(text));
  if (stableTask) {
    return {decision: 'none', reason: 'stable_task'};
  }
  if (personal) {
    return {decision: 'auto', reason: 'personal'};
  }
  if (input.hasAttachment || input.otherToolMatches) {
    return {decision: 'auto', reason: 'default'};
  }
  if (hasFreshTerm(text) && !hasStableGuard(text)) {
    return {decision: 'force', reason: 'fresh_term'};
  }
  if (input.knowledgeCutoff && mentionsLaterDate(text, input.knowledgeCutoff)) {
    return {decision: 'force', reason: 'later_date'};
  }
  return {decision: 'auto', reason: 'default'};
}

/**
 * Optional model pre-pass for the `auto` band: one word ("search" or
 * "answer"), about 130 prompt tokens and at most 4 generated ones.
 */
export const CLASSIFY_PROMPT =
  'Decide how to handle the user message. Answer with exactly one word. Write "search" if a correct answer needs information from the web that may have changed recently or that you do not reliably know (news, prices, weather, scores, schedules, releases, current office holders, specific facts about small places, products or people). Write "answer" if you can answer from general knowledge, or the task is writing, maths, translation, coding, advice or conversation.';

export async function classifySearchNeed(options: {
  engine: CompletionEngine;
  userText: string;
  /** Today's date line, so "this year" can be judged. */
  dateLine?: string;
  signal?: AbortSignal;
}): Promise<'search' | 'answer' | null> {
  const messages: ChatMessage[] = [
    {
      role: 'system',
      content: [CLASSIFY_PROMPT, options.dateLine].filter(Boolean).join('\n'),
    },
    {role: 'user', content: options.userText.slice(0, 600)},
  ];
  try {
    // Plain text, no grammar: a response-format grammar makes Gemma 4 think
    // first (and is a known crash with thinking on llama.rn), and one word
    // needs none.
    const result = await options.engine.completion({
      messages,
      n_predict: 4,
      temperature: 0,
      enable_thinking: false,
    } as never);
    const text = (
      (result as {content?: string}).content ??
      result.text ??
      ''
    ).toLowerCase();
    const match = /\b(search|answer)\b/.exec(text);
    return match ? (match[1] as 'search' | 'answer') : null;
  } catch {
    return null;
  }
}
