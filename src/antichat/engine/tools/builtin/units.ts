/**
 * Unit converter. Fixed physical units only: currencies need live rates and
 * are answered by web search instead. Works offline.
 */
import type {ConversionCard} from '../cards';
import type {AntichatTool} from '../types';
import {formatNumber} from './calculator';

interface Unit {
  quantity: string;
  /** Multiply by this to get the quantity's base unit. */
  factor: number;
  /** Added after scaling (temperature only). */
  offset?: number;
  label: string;
  names: string[];
}

const unit = (
  quantity: string,
  factor: number,
  label: string,
  names: string[],
  offset?: number,
): Unit => ({quantity, factor, label, names, offset});

const UNITS: Unit[] = [
  // length — base metre
  unit('length', 0.001, 'mm', [
    'mm',
    'millimeter',
    'millimetre',
    'millimeters',
    'millimetres',
  ]),
  unit('length', 0.01, 'cm', [
    'cm',
    'centimeter',
    'centimetre',
    'centimeters',
    'centimetres',
  ]),
  unit('length', 1, 'm', ['m', 'meter', 'metre', 'meters', 'metres']),
  unit('length', 1000, 'km', [
    'km',
    'kilometer',
    'kilometre',
    'kilometers',
    'kilometres',
  ]),
  unit('length', 0.0254, 'in', ['in', 'inch', 'inches', '"']),
  unit('length', 0.3048, 'ft', ['ft', 'foot', 'feet', "'"]),
  unit('length', 0.9144, 'yd', ['yd', 'yard', 'yards']),
  unit('length', 1609.344, 'mi', ['mi', 'mile', 'miles']),
  unit('length', 1852, 'nmi', ['nmi', 'nautical mile', 'nautical miles']),
  // mass — base kilogram
  unit('mass', 1e-6, 'mg', ['mg', 'milligram', 'milligrams']),
  unit('mass', 0.001, 'g', ['g', 'gram', 'grams', 'gramme', 'grammes']),
  unit('mass', 1, 'kg', ['kg', 'kilogram', 'kilograms', 'kilo', 'kilos']),
  unit('mass', 1000, 't', [
    't',
    'tonne',
    'tonnes',
    'metric ton',
    'metric tons',
  ]),
  unit('mass', 0.028349523125, 'oz', ['oz', 'ounce', 'ounces']),
  unit('mass', 0.45359237, 'lb', ['lb', 'lbs', 'pound', 'pounds']),
  unit('mass', 6.35029318, 'st', ['st', 'stone', 'stones']),
  // volume — base litre
  unit('volume', 0.001, 'ml', [
    'ml',
    'milliliter',
    'millilitre',
    'milliliters',
    'millilitres',
  ]),
  unit('volume', 1, 'l', ['l', 'liter', 'litre', 'liters', 'litres']),
  unit('volume', 0.00492892159375, 'tsp', ['tsp', 'teaspoon', 'teaspoons']),
  unit('volume', 0.01478676478125, 'tbsp', [
    'tbsp',
    'tablespoon',
    'tablespoons',
  ]),
  unit('volume', 0.0295735295625, 'fl oz', [
    'fl oz',
    'floz',
    'fluid ounce',
    'fluid ounces',
  ]),
  unit('volume', 0.2365882365, 'cup', ['cup', 'cups']),
  unit('volume', 0.473176473, 'pt', ['pt', 'pint', 'pints']),
  unit('volume', 0.946352946, 'qt', ['qt', 'quart', 'quarts']),
  unit('volume', 3.785411784, 'gal', ['gal', 'gallon', 'gallons']),
  unit('volume', 1000, 'm³', [
    'm3',
    'm³',
    'cubic meter',
    'cubic metre',
    'cubic meters',
    'cubic metres',
  ]),
  // temperature — base kelvin
  unit('temperature', 1, '°C', ['c', '°c', 'celsius', 'centigrade'], 273.15),
  unit('temperature', 5 / 9, '°F', ['f', '°f', 'fahrenheit'], 459.67 * (5 / 9)),
  unit('temperature', 1, 'K', ['k', 'kelvin']),
  // speed — base m/s
  unit('speed', 1, 'm/s', [
    'm/s',
    'mps',
    'meters per second',
    'metres per second',
  ]),
  unit('speed', 1 / 3.6, 'km/h', [
    'km/h',
    'kmh',
    'kph',
    'kilometers per hour',
    'kilometres per hour',
  ]),
  unit('speed', 0.44704, 'mph', ['mph', 'miles per hour']),
  unit('speed', 0.514444, 'kn', ['kn', 'knot', 'knots']),
  // area — base m²
  unit('area', 1, 'm²', [
    'm2',
    'm²',
    'sqm',
    'square meter',
    'square metre',
    'square meters',
    'square metres',
  ]),
  unit('area', 1e6, 'km²', [
    'km2',
    'km²',
    'square kilometer',
    'square kilometre',
    'square kilometers',
    'square kilometres',
  ]),
  unit('area', 0.09290304, 'ft²', [
    'ft2',
    'ft²',
    'sqft',
    'sq ft',
    'square foot',
    'square feet',
  ]),
  unit('area', 4046.8564224, 'acre', ['acre', 'acres']),
  unit('area', 10000, 'ha', ['ha', 'hectare', 'hectares']),
  // time — base second
  unit('time', 0.001, 'ms', ['ms', 'millisecond', 'milliseconds']),
  unit('time', 1, 's', ['s', 'sec', 'secs', 'second', 'seconds']),
  unit('time', 60, 'min', ['min', 'mins', 'minute', 'minutes']),
  unit('time', 3600, 'h', ['h', 'hr', 'hrs', 'hour', 'hours']),
  unit('time', 86400, 'd', ['d', 'day', 'days']),
  unit('time', 604800, 'wk', ['wk', 'week', 'weeks']),
  // data — base byte
  unit('data', 1, 'B', ['b', 'byte', 'bytes']),
  unit('data', 1e3, 'kB', ['kb', 'kilobyte', 'kilobytes']),
  unit('data', 1e6, 'MB', ['mb', 'megabyte', 'megabytes']),
  unit('data', 1e9, 'GB', ['gb', 'gigabyte', 'gigabytes']),
  unit('data', 1e12, 'TB', ['tb', 'terabyte', 'terabytes']),
  unit('data', 1024, 'KiB', ['kib', 'kibibyte', 'kibibytes']),
  unit('data', 1048576, 'MiB', ['mib', 'mebibyte', 'mebibytes']),
  unit('data', 1073741824, 'GiB', ['gib', 'gibibyte', 'gibibytes']),
  // energy — base joule
  unit('energy', 1, 'J', ['j', 'joule', 'joules']),
  unit('energy', 1000, 'kJ', ['kj', 'kilojoule', 'kilojoules']),
  unit('energy', 4.184, 'cal', ['cal', 'calorie', 'calories']),
  unit('energy', 4184, 'kcal', ['kcal', 'kilocalorie', 'kilocalories']),
  unit('energy', 3.6e6, 'kWh', ['kwh', 'kilowatt hour', 'kilowatt hours']),
  // pressure — base pascal
  unit('pressure', 1e5, 'bar', ['bar']),
  unit('pressure', 6894.757293, 'psi', ['psi']),
  unit('pressure', 101325, 'atm', ['atm', 'atmosphere', 'atmospheres']),
  unit('pressure', 1000, 'kPa', ['kpa', 'kilopascal', 'kilopascals']),
  // fuel economy is reciprocal and handled separately below
];

const CURRENCY =
  /^(?:usd|eur|gbp|jpy|chf|cad|aud|cny|inr|brl|mxn|sek|nok|dkk|pln|try|krw|dollars?|euros?|pounds? sterling|yen|francs?|rupees?|bitcoin|btc|eth|\$|€|£|¥)$/i;

const LOOKUP = new Map<string, Unit>();
for (const entry of UNITS) {
  for (const name of entry.names) {
    // Case matters only where it disambiguates (mb vs MB is not attempted).
    if (!LOOKUP.has(name.toLowerCase())) {
      LOOKUP.set(name.toLowerCase(), entry);
    }
  }
}

export function findUnit(name: string): Unit | undefined {
  const key = name
    .trim()
    .toLowerCase()
    .replace(/^degrees?\s+/, '')
    .replace(/\.$/, '')
    .replace(/\s+/g, ' ');
  return LOOKUP.get(key) ?? LOOKUP.get(key.replace(/s$/, ''));
}

export function isCurrency(name: string): boolean {
  return CURRENCY.test(name.trim());
}

export interface Conversion {
  value: number;
  from: Unit;
  to: Unit;
  result: number;
}

/** Convert `value` between two named units of the same quantity. */
export function convertUnits(
  value: number,
  from: string,
  to: string,
): Conversion {
  if (isCurrency(from) || isCurrency(to)) {
    throw new Error(
      'currencies need live exchange rates; use web_search for those',
    );
  }
  const source = findUnit(from);
  const target = findUnit(to);
  if (!source) {
    throw new Error(`unknown unit "${from}"`);
  }
  if (!target) {
    throw new Error(`unknown unit "${to}"`);
  }
  if (source.quantity !== target.quantity) {
    throw new Error(
      `cannot convert ${source.quantity} (${source.label}) to ${target.quantity} (${target.label})`,
    );
  }
  const base = value * source.factor + (source.offset ?? 0);
  const result = (base - (target.offset ?? 0)) / target.factor;
  return {value, from: source, to: target, result};
}

/** "5 miles in km", "72 f to c", "convert 3.5 cups to ml". */
export function parseConversion(
  text: string,
): {value: number; from: string; to: string} | null {
  const match =
    /(-?\d[\d,]*\.?\d*)\s*(°?\s?[A-Za-z"'²³/ ]+?)\s+(?:to|in|into|as|->|→|=)\s+(°?\s?[A-Za-z"'²³/ ]+?)\s*\??$/i.exec(
      text.trim().replace(/^convert\s+/i, ''),
    );
  if (!match) {
    return null;
  }
  return {
    value: Number(match[1].replace(/,/g, '')),
    from: match[2].trim(),
    to: match[3].trim(),
  };
}

const round = (value: number): string => {
  const abs = Math.abs(value);
  if (abs !== 0 && abs < 0.01) {
    return formatNumber(Number(value.toPrecision(3)));
  }
  return formatNumber(Number(value.toPrecision(6)));
};

export const convertUnitsTool: AntichatTool = {
  name: 'convert_units',
  description:
    'Convert a value between units of length, mass, volume, temperature, speed, area, time, data, energy or pressure. Not for currencies.',
  parameters: {
    type: 'object',
    properties: {
      value: {type: 'number', description: 'The amount to convert'},
      from: {type: 'string', description: 'Unit to convert from, e.g. "mi"'},
      to: {type: 'string', description: 'Unit to convert to, e.g. "km"'},
    },
    required: ['value', 'from', 'to'],
    additionalProperties: false,
  },
  kind: 'local',
  tier: 'always',
  keywords: [
    'unit',
    'units',
    'miles',
    'km',
    'fahrenheit',
    'celsius',
    'pounds',
    'kg',
    'cups',
  ],
  timeoutMs: 2000,
  example: {value: 5, from: 'mi', to: 'km'},
  normalize: args => {
    const out: Record<string, unknown> = {
      value: args.value ?? args.amount ?? args.quantity,
      from: args.from ?? args.from_unit ?? args.source ?? args.unit,
      to: args.to ?? args.to_unit ?? args.target,
    };
    // "5 mi" in one field.
    if (typeof out.from === 'string' && out.value === undefined) {
      const split = /^(-?\d[\d,]*\.?\d*)\s*(.+)$/.exec(out.from.trim());
      if (split) {
        out.value = Number(split[1].replace(/,/g, ''));
        out.from = split[2];
      }
    }
    Object.keys(out).forEach(key => out[key] === undefined && delete out[key]);
    return out;
  },
  async execute(args) {
    try {
      const done = convertUnits(
        Number(args.value),
        String(args.from),
        String(args.to),
      );
      const text = `${round(done.value)} ${done.from.label} = ${round(done.result)} ${done.to.label}`;
      const card: ConversionCard = {
        type: 'conversion',
        quantity: done.from.quantity,
        from: {
          value: done.value,
          unit: done.from.label,
          label: done.from.names[1] ?? done.from.label,
        },
        to: {
          value: done.result,
          unit: done.to.label,
          label: done.to.names[1] ?? done.to.label,
        },
        text,
      };
      return {text, card};
    } catch (error) {
      return {
        text: `convert_units: ${(error as Error).message}.`,
        isError: true,
      };
    }
  },
};
