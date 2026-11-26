/**
 * Crisis rule (H16): a short prompt rule plus a bundled helpline table.
 *
 * The model is told never to write a number from memory. When the newest
 * message looks like a crisis, the verified helpline for the user's country
 * is handed to the model as turn context and reported in `meta.crisis`, so
 * the app (M8) can show it as a card whatever the model writes.
 */
import helplineData from './data/helplines.json';

export interface Helpline {
  countryCode: string;
  /** Absent when the country has no confirmed national crisis line. */
  name?: string;
  phone?: string;
  text?: string;
  allHours?: boolean;
  emergency: string;
}

interface HelplineTable {
  checked: string;
  fallback: {name: string; url: string; emergency: string};
  countries: Record<string, Omit<Helpline, 'countryCode'>>;
}

const table = helplineData as unknown as HelplineTable;

export const HELPLINES_CHECKED = table.checked;
export const HELPLINE_FALLBACK = table.fallback;

/** Country from "de-DE", "en_US", "DE"… or undefined. */
export function countryFromLocale(locale?: string | null): string | undefined {
  if (!locale) {
    return undefined;
  }
  const parts = locale.replace(/_/g, '-').split('-');
  const region = parts.length === 1 ? parts[0] : parts[parts.length - 1];
  return /^[A-Za-z]{2}$/.test(region) &&
    (parts.length > 1 || region === region.toUpperCase())
    ? region.toUpperCase()
    : undefined;
}

export function helplineFor(countryCode?: string | null): Helpline | null {
  const code = countryCode?.toUpperCase();
  const entry = code ? table.countries[code] : undefined;
  return entry && code ? {countryCode: code, ...entry} : null;
}

export function listHelplines(): Helpline[] {
  return Object.entries(table.countries).map(([countryCode, entry]) => ({
    countryCode,
    ...entry,
  }));
}

// Deliberately specific phrases: a false card on "this bug is killing me"
// would be worse than none. First person, self-directed.
const SIGNALS: RegExp[] = [
  /\b(?:kill|killing|hurt|hurting|harm|harming|cut|cutting) (?:myself|my ?self)\b/i,
  /\b(?:suicid(?:e|al)|end(?:ing)? (?:my|it all|my own) ?(?:life)?|take my (?:own )?life|want to die|wanna die|(?:don'?t|do not|no longer) want to (?:live|be alive|exist|be here)(?: any ?more)?|can(?:'?t|not) go on(?: living)?|better off dead|no reason to live|self[- ]harm)\b/i,
  /\b(?:mich (?:umbringen|töten|selbst verletzen)|selbstmord|suizid|nicht mehr leben|will sterben|mir das leben nehmen)\b/i,
  /\b(?:suicidarme|suicidio|matarme|quitarme la vida|no quiero vivir|quiero morir(?:me)?|hacerme daño)\b/i,
  /\b(?:me suicider|suicide|me tuer|mettre fin à mes jours|envie de mourir|plus envie de vivre|me faire du mal)\b/i,
  /\b(?:suicidarmi|uccidermi|togliermi la vita|voglio morire|farmi del male)\b/i,
  /\b(?:me matar|suicídio|tirar a minha vida|quero morrer|não quero mais viver)\b/i,
  /\b(?:zelfmoord|mezelf (?:doden|pijn doen)|wil dood|niet meer leven)\b/i,
  /死にたい|自殺|消えたい|自杀|自殺|不想活|想死|죽고 ?싶|자살/,
  /(?:покончить с собой|самоубийств|хочу умереть|не хочу жить)/i,
];

/** Does the text contain a first-person crisis signal? */
export function detectCrisis(text: string): boolean {
  const sample = (text || '').slice(0, 8000);
  return SIGNALS.some(pattern => pattern.test(sample));
}

/**
 * Instruction handed to the model with a crisis message, built only from the
 * verified table. Worded as a hard limit: Gemma 4 E2B otherwise answers with
 * numbers from memory (it gave 988 and 111 to a user in the UK).
 */
export function helplineContextLine(countryCode?: string | null): string {
  const line = helplineFor(countryCode);
  const lead = 'Instruction: the user may be in crisis.';
  if (line?.name && line.phone) {
    const text = line.text ? `, text ${line.text}` : '';
    const hours = line.allHours ? ' (open 24/7)' : '';
    return `${lead} The ONLY helpline you may give is this verified one for where the user is: ${line.name}, phone ${line.phone}${text}${hours}. Emergency number: ${line.emergency}. Do not give any other phone number and do not mention other countries.`;
  }
  const emergency = line?.emergency ?? HELPLINE_FALLBACK.emergency;
  return `${lead} No verified crisis line is known for where the user is. Suggest ${HELPLINE_FALLBACK.url} to find one, and the local emergency number (${emergency}) if they are in danger. Do not give any other phone number and do not mention other countries.`;
}

const PHONE_LIKE = /\+?\d(?:[\d\s().-]*\d)?/g;
const digitsOf = (value: string): string => value.replace(/\D/g, '');

/** Digit strings the model may write for this country. */
function allowedDigits(countryCode?: string | null): Set<string> {
  const line = helplineFor(countryCode);
  const allowed = new Set<string>(['24', '7', '247']);
  const add = (value?: string) => {
    if (!value) {
      return;
    }
    for (const part of value.split('/')) {
      const digits = digitsOf(part);
      if (digits) {
        allowed.add(digits);
      }
    }
    // "116 123" may be written group by group.
    allowed.add(digitsOf(value));
  };
  add(line?.phone);
  add(line?.text);
  add(line?.emergency ?? HELPLINE_FALLBACK.emergency);
  return allowed;
}

/** Phone-like numbers in `text` that are not in the verified table. */
export function unverifiedNumbers(
  text: string,
  countryCode?: string | null,
): string[] {
  const allowed = allowedDigits(countryCode);
  const found: string[] = [];
  for (const match of text.matchAll(PHONE_LIKE)) {
    const digits = digitsOf(match[0]);
    if (digits.length >= 3 && !allowed.has(digits)) {
      found.push(match[0].trim());
    }
  }
  return found;
}

/**
 * Safety net for the display path of a crisis reply: sentences that give a
 * phone number the table does not know are removed. The app's helpline card
 * carries the right number whatever the model wrote.
 */
export function removeUnverifiedNumbers(
  text: string,
  countryCode?: string | null,
): {text: string; removed: string[]} {
  const removed: string[] = [];
  const kept = text.split(/(?<=[.!?。！？])\s+|\n+/).filter(sentence => {
    const bad = unverifiedNumbers(sentence, countryCode);
    removed.push(...bad);
    return bad.length === 0;
  });
  return {
    text: removed.length ? kept.join(' ').trim() : text,
    removed,
  };
}
