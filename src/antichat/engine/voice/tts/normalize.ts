/**
 * Turns one unit of a Markdown answer into words a voice can say: no markup,
 * no emoji, no link targets; symbols, units and common abbreviations spelled
 * out in English, German, Spanish and French (other languages keep the
 * symbols and rely on the voice).
 *
 * Digits stay digits: the system voices read them natively and the speech
 * library spells them out for its neural engines.
 */
import type {SpeechUnitKind} from './sentenceSplitter';

export interface NormalizeOptions {
  language?: string;
  kind?: SpeechUnitKind;
  /** Said in place of a code block; '' skips it. Defaults per language. */
  codePlaceholder?: string;
}

interface Words {
  code: string;
  and: string;
  percent: string;
  plus: string;
  equals: string;
  to: string;
  times: string;
  degrees: string;
  celsius: string;
  fahrenheit: string;
  approx: string;
  currency: Record<string, string>;
  units: Record<string, string>;
  abbreviations: [RegExp, string][];
}

const UNITS_EN = {
  km: 'kilometers',
  m: 'meters',
  cm: 'centimeters',
  mm: 'millimeters',
  kg: 'kilograms',
  g: 'grams',
  mg: 'milligrams',
  l: 'liters',
  ml: 'milliliters',
  'km/h': 'kilometers per hour',
  mph: 'miles per hour',
  'm/s': 'meters per second',
  kb: 'kilobytes',
  mb: 'megabytes',
  gb: 'gigabytes',
  tb: 'terabytes',
  kwh: 'kilowatt hours',
  kw: 'kilowatts',
  hz: 'hertz',
  khz: 'kilohertz',
  ms: 'milliseconds',
  min: 'minutes',
  h: 'hours',
  lb: 'pounds',
  oz: 'ounces',
  ft: 'feet',
  mi: 'miles',
};

const abbr = (pattern: string, flags = 'gi'): RegExp =>
  new RegExp(`(?<![\\p{L}\\p{N}])${pattern}(?![\\p{L}\\p{N}])`, flags + 'u');

const LANGUAGES: Record<string, Words> = {
  en: {
    code: 'Here is a code example.',
    and: 'and',
    percent: 'percent',
    plus: 'plus',
    equals: 'equals',
    to: 'to',
    times: 'times',
    degrees: 'degrees',
    celsius: 'degrees Celsius',
    fahrenheit: 'degrees Fahrenheit',
    approx: 'about',
    currency: {$: 'dollars', '€': 'euros', '£': 'pounds', '¥': 'yen'},
    units: UNITS_EN,
    abbreviations: [
      [abbr('e\\.g\\.,?'), 'for example,'],
      [abbr('i\\.e\\.,?'), 'that is,'],
      [abbr('etc\\.'), 'et cetera.'],
      [abbr('vs\\.?'), 'versus'],
      [abbr('approx\\.'), 'approximately'],
      [abbr('w/o'), 'without'],
    ],
  },
  de: {
    code: 'Hier ist ein Codebeispiel.',
    and: 'und',
    percent: 'Prozent',
    plus: 'plus',
    equals: 'gleich',
    to: 'bis',
    times: 'mal',
    degrees: 'Grad',
    celsius: 'Grad Celsius',
    fahrenheit: 'Grad Fahrenheit',
    approx: 'ungefähr',
    currency: {$: 'Dollar', '€': 'Euro', '£': 'Pfund', '¥': 'Yen'},
    units: {
      km: 'Kilometer',
      m: 'Meter',
      cm: 'Zentimeter',
      mm: 'Millimeter',
      kg: 'Kilogramm',
      g: 'Gramm',
      mg: 'Milligramm',
      l: 'Liter',
      ml: 'Milliliter',
      'km/h': 'Kilometer pro Stunde',
      'm/s': 'Meter pro Sekunde',
      kb: 'Kilobyte',
      mb: 'Megabyte',
      gb: 'Gigabyte',
      tb: 'Terabyte',
      kwh: 'Kilowattstunden',
      kw: 'Kilowatt',
      hz: 'Hertz',
      ms: 'Millisekunden',
      min: 'Minuten',
      h: 'Stunden',
    },
    abbreviations: [
      [abbr('z\\.\\s?B\\.'), 'zum Beispiel'],
      [abbr('d\\.\\s?h\\.'), 'das heißt'],
      [abbr('u\\.\\s?a\\.'), 'unter anderem'],
      [abbr('usw\\.'), 'und so weiter.'],
      [abbr('bzw\\.'), 'beziehungsweise'],
      [abbr('ca\\.'), 'circa'],
      [abbr('ggf\\.'), 'gegebenenfalls'],
      [abbr('evtl\\.'), 'eventuell'],
      [abbr('inkl\\.'), 'inklusive'],
      [abbr('vgl\\.'), 'vergleiche'],
      [abbr('Nr\\.'), 'Nummer'],
    ],
  },
  es: {
    code: 'Aquí hay un ejemplo de código.',
    and: 'y',
    percent: 'por ciento',
    plus: 'más',
    equals: 'igual a',
    to: 'a',
    times: 'veces',
    degrees: 'grados',
    celsius: 'grados Celsius',
    fahrenheit: 'grados Fahrenheit',
    approx: 'aproximadamente',
    currency: {$: 'dólares', '€': 'euros', '£': 'libras', '¥': 'yenes'},
    units: {
      km: 'kilómetros',
      m: 'metros',
      cm: 'centímetros',
      mm: 'milímetros',
      kg: 'kilogramos',
      g: 'gramos',
      l: 'litros',
      ml: 'mililitros',
      'km/h': 'kilómetros por hora',
      gb: 'gigabytes',
      mb: 'megabytes',
      min: 'minutos',
      h: 'horas',
    },
    abbreviations: [
      [abbr('p\\.\\s?ej\\.'), 'por ejemplo'],
      [abbr('etc\\.'), 'etcétera.'],
      [abbr('Sr\\.'), 'señor'],
      [abbr('Sra\\.'), 'señora'],
      [abbr('Ud\\.'), 'usted'],
    ],
  },
  fr: {
    code: 'Voici un exemple de code.',
    and: 'et',
    percent: 'pour cent',
    plus: 'plus',
    equals: 'égale',
    to: 'à',
    times: 'fois',
    degrees: 'degrés',
    celsius: 'degrés Celsius',
    fahrenheit: 'degrés Fahrenheit',
    approx: 'environ',
    currency: {$: 'dollars', '€': 'euros', '£': 'livres', '¥': 'yens'},
    units: {
      km: 'kilomètres',
      m: 'mètres',
      cm: 'centimètres',
      mm: 'millimètres',
      kg: 'kilogrammes',
      g: 'grammes',
      l: 'litres',
      ml: 'millilitres',
      'km/h': 'kilomètres par heure',
      go: 'gigaoctets',
      mo: 'mégaoctets',
      min: 'minutes',
      h: 'heures',
    },
    abbreviations: [
      [abbr('p\\.\\s?ex\\.'), 'par exemple'],
      [abbr('etc\\.'), 'et cetera.'],
      [abbr('c\\.-à-d\\.'), "c'est-à-dire"],
      [abbr('Mme'), 'madame'],
      [abbr('M\\.', 'g'), 'monsieur'],
    ],
  },
};

const baseLanguage = (tag?: string) =>
  (tag ?? 'en').toLowerCase().split(/[-_]/)[0]!;

/** Markup only: what is left reads like the plain sentence. */
export function stripMarkdown(input: string): string {
  let text = input;
  text = text.replace(/<think>[\s\S]*?(<\/think>|$)/g, ' ');
  // Table rows: separator rows vanish, cells become a comma list.
  if (/^\s*\|/.test(text)) {
    if (/^\s*\|?[\s:|-]+\|?\s*$/.test(text)) {
      return '';
    }
    text = text
      .trim()
      .replace(/^\||\|$/g, '')
      .split('|')
      .map(cell => cell.trim())
      .filter(Boolean)
      .join(', ');
  }
  text = text
    .replace(/^\s{0,3}#{1,6}\s+/, '')
    .replace(/^\s{0,3}>\s?/gm, '')
    .replace(/^\s*([-*_])(\s*\1){2,}\s*$/gm, ' ')
    .replace(/^\s*[-*+•]\s+(\[[ xX]\]\s+)?/, '')
    .replace(/^\s*(\d{1,3})[.)]\s+/, '$1, ')
    .replace(/!\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/\[([^\]]+)\]\((?:[^()]|\([^)]*\))*\)/g, '$1')
    .replace(/\[([^\]]+)\]\[[^\]]*\]/g, '$1')
    .replace(/\[\^?\d+\]|【[^】]*】/g, '')
    .replace(/<((?:https?:\/\/|www\.)[^>\s]+)>/g, '$1')
    .replace(/<\/?[a-zA-Z][^>]*>/g, ' ')
    .replace(/\\\(|\\\)|\\\[|\\\]|\$\$/g, ' ')
    .replace(/(\*\*|__|~~)(?=\S)([\s\S]*?\S)\1/g, '$2')
    .replace(
      /(?<![\p{L}\p{N}*])\*(?=\S)([^*\n]*?\S)\*(?![\p{L}\p{N}*])/gu,
      '$1',
    )
    .replace(/(?<![\p{L}\p{N}_])_(?=\S)([^_\n]*?\S)_(?![\p{L}\p{N}_])/gu, '$1')
    .replace(/`+([^`]*)`+/g, '$1')
    .replace(/\*\*|__|~~|`/g, '')
    .replace(/\\([\\`*_{}[\]()#+\-.!|>~])/g, '$1');
  return text;
}

const EMOJI =
  /[\p{Extended_Pictographic}\p{Emoji_Modifier}\u{1F1E6}-\u{1F1FF}\u{FE0F}\u{200D}\u{20E3}\u{E0020}-\u{E007F}]/gu;

function speakUrls(text: string): string {
  return text.replace(
    /\b(?:https?:\/\/|www\.)([^\s/?#)]+)[^\s)]*/gi,
    (_match, host: string) => host.replace(/^www\./, ''),
  );
}

function speakSymbols(text: string, words: Words): string {
  const num = '(\\d+(?:[.,]\\d+)*)';
  let out = text;
  // Currency: "$5.50" and "5,50 €" → "5.50 dollars"
  for (const [symbol, name] of Object.entries(words.currency)) {
    const s = symbol.replace('$', '\\$');
    out = out
      .replace(new RegExp(`${s}\\s?${num}`, 'g'), `$1 ${name}`)
      .replace(new RegExp(`${num}\\s?${s}`, 'g'), `$1 ${name}`);
  }
  out = out
    .replace(new RegExp(`${num}\\s?°\\s?C\\b`, 'g'), `$1 ${words.celsius}`)
    .replace(new RegExp(`${num}\\s?°\\s?F\\b`, 'g'), `$1 ${words.fahrenheit}`)
    .replace(new RegExp(`${num}\\s?°`, 'g'), `$1 ${words.degrees}`)
    .replace(new RegExp(`${num}\\s?%`, 'g'), `$1 ${words.percent}`)
    .replace(
      new RegExp(`${num}\\s?[x×](?![\\p{L}\\p{N}])`, 'gu'),
      `$1 ${words.times}`,
    )
    .replace(
      new RegExp(`${num}\\s?[–-]\\s?${num}(?![\\d-])`, 'g'),
      (match, a, b, at, all) =>
        // A date or phone number ("2024-05-01") is not a range.
        /[\d-]$/.test(all.slice(0, at)) ? match : `${a} ${words.to} ${b}`,
    );
  // Units directly after a number: "5 km", "16GB"
  out = out.replace(
    new RegExp(
      `${num}\\s?([a-zA-Z]{1,3}(?:/[a-zA-Z]{1,2})?)(?![\\p{L}\\p{N}/])`,
      'gu',
    ),
    (match, value: string, unit: string) => {
      const name = words.units[unit.toLowerCase()];
      // "m" and "h" are too ambiguous with a space-less glue ("5m" is fine).
      return name ? `${value} ${name}` : match;
    },
  );
  return out
    .replace(/\s&\s/g, ` ${words.and} `)
    .replace(/(?<=\d)\s?\+\s?(?=\d)/g, ` ${words.plus} `)
    .replace(/(?<=[\p{L}\p{N}])\s=\s(?=[\p{L}\p{N}])/gu, ` ${words.equals} `)
    .replace(/[≈~](?=\s?\d)/g, `${words.approx} `)
    .replace(/\s?(?:→|->|=>)\s?/g, ', ');
}

export function normalizeForSpeech(
  raw: string,
  options: NormalizeOptions = {},
): string {
  const language = baseLanguage(options.language);
  const words = LANGUAGES[language];
  if (options.kind === 'code') {
    return options.codePlaceholder ?? words?.code ?? '';
  }
  let text = stripMarkdown(raw);
  text = speakUrls(text).replace(EMOJI, ' ');
  if (words) {
    for (const [pattern, spoken] of words.abbreviations) {
      text = text.replace(pattern, spoken);
    }
    text = speakSymbols(text, words);
  }
  text = text
    .replace(/[“”«»„]/g, '"')
    .replace(/\s+/g, ' ')
    .replace(/\s+([,.!?;:])/g, '$1')
    .replace(/([,.])\1+/g, '$1')
    .replace(/,\./g, '.')
    .trim();
  // Nothing left to say ("---", ":)", a lone emoji).
  return /[\p{L}\p{N}]/u.test(text) ? text : '';
}
