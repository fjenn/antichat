/**
 * Argument validation against the JSON-schema subset tool definitions use
 * (type, properties, required, additionalProperties, enum, items, minimum,
 * maximum, minLength, maxLength, pattern). Dependency-free: the schemas are
 * data that may arrive at run time (MCP), so they cannot be zod objects.
 *
 * Validation is forgiving where a small model's slip has one obvious
 * meaning: `"5"` for an integer, `5` for a string, a bare string where an
 * array of strings is wanted, `"true"` for a boolean, null for an optional
 * argument, unknown keys. Those are coerced and reported in `fixes`; anything
 * else is a problem the repair prompt quotes.
 */
import type {JsonSchema} from './types';

export interface ValidationResult {
  ok: boolean;
  /** The arguments after coercion (use these for the call). */
  value: Record<string, unknown>;
  /** Human-readable problems, most important first. */
  problems: string[];
  /** Silent corrections that were applied. */
  fixes: string[];
}

const typeOf = (value: unknown): string => {
  if (value === null) {
    return 'null';
  }
  if (Array.isArray(value)) {
    return 'array';
  }
  if (typeof value === 'number') {
    return Number.isInteger(value) ? 'integer' : 'number';
  }
  return typeof value;
};

const allows = (schema: JsonSchema, type: string): boolean => {
  const declared = schema.type;
  if (declared === undefined) {
    return true;
  }
  const list: string[] = Array.isArray(declared) ? declared : [declared];
  return list.includes(type) || (type === 'integer' && list.includes('number'));
};

const primaryType = (schema: JsonSchema): string | undefined => {
  const declared = schema.type;
  if (Array.isArray(declared)) {
    return declared.find(type => type !== 'null');
  }
  return declared;
};

interface Walk {
  problems: string[];
  fixes: string[];
}

function coerce(
  value: unknown,
  schema: JsonSchema,
  path: string,
  walk: Walk,
): unknown {
  const want = primaryType(schema);
  const have = typeOf(value);
  if (want === undefined || allows(schema, have)) {
    return value;
  }
  if ((want === 'integer' || want === 'number') && typeof value === 'string') {
    const cleaned = value.trim().replace(/,(?=\d{3}\b)/g, '');
    if (/^-?\d+(\.\d+)?$/.test(cleaned)) {
      const parsed = Number(cleaned);
      if (want === 'number' || Number.isInteger(parsed)) {
        walk.fixes.push(`${path}: "${value}" read as a number`);
        return parsed;
      }
    }
  }
  if (want === 'integer' && typeof value === 'number') {
    if (Math.abs(value - Math.round(value)) < 1e-9) {
      return Math.round(value);
    }
  }
  if (want === 'string' && (have === 'integer' || have === 'number')) {
    walk.fixes.push(`${path}: number read as text`);
    return String(value);
  }
  if (want === 'string' && have === 'boolean') {
    return String(value);
  }
  if (want === 'boolean' && typeof value === 'string') {
    const lowered = value.trim().toLowerCase();
    if (lowered === 'true' || lowered === 'false') {
      walk.fixes.push(`${path}: "${value}" read as a boolean`);
      return lowered === 'true';
    }
  }
  if (want === 'array' && have !== 'array' && have !== 'null') {
    if (typeof value === 'string') {
      const trimmed = value.trim();
      if (trimmed.startsWith('[')) {
        try {
          const parsed = JSON.parse(trimmed);
          if (Array.isArray(parsed)) {
            walk.fixes.push(`${path}: text read as a list`);
            return parsed;
          }
        } catch {
          // fall through to the single-item list
        }
      }
      const itemType = primaryType(schema.items ?? {});
      if (itemType === 'string' || itemType === undefined) {
        walk.fixes.push(`${path}: single value wrapped in a list`);
        return /[,;]/.test(trimmed) &&
          !/\s/.test(trimmed.replace(/[,;]\s*/g, ''))
          ? trimmed.split(/[,;]\s*/).filter(Boolean)
          : [trimmed];
      }
    }
    if (allows(schema.items ?? {}, have)) {
      walk.fixes.push(`${path}: single value wrapped in a list`);
      return [value];
    }
  }
  if (want === 'object' && typeof value === 'string') {
    try {
      const parsed = JSON.parse(value);
      if (typeOf(parsed) === 'object') {
        walk.fixes.push(`${path}: text read as an object`);
        return parsed;
      }
    } catch {
      // not JSON
    }
  }
  return value;
}

function check(
  input: unknown,
  schema: JsonSchema,
  path: string,
  walk: Walk,
): unknown {
  const value = coerce(input, schema, path, walk);
  const have = typeOf(value);
  const label = path || 'arguments';
  if (!allows(schema, have)) {
    walk.problems.push(`${label} must be ${describeType(schema)}, got ${have}`);
    return value;
  }
  if (Array.isArray(schema.enum) && !schema.enum.includes(value)) {
    const match =
      typeof value === 'string'
        ? schema.enum.find(
            (option: unknown) =>
              typeof option === 'string' &&
              option.toLowerCase() === value.trim().toLowerCase(),
          )
        : undefined;
    if (match !== undefined) {
      walk.fixes.push(`${label}: "${value}" matched to "${match}"`);
      return match;
    }
    walk.problems.push(
      `${label} must be one of ${schema.enum
        .map((option: unknown) => JSON.stringify(option))
        .join(', ')}`,
    );
    return value;
  }
  if (typeof value === 'number') {
    if (typeof schema.minimum === 'number' && value < schema.minimum) {
      walk.problems.push(`${label} must be at least ${schema.minimum}`);
    }
    if (typeof schema.maximum === 'number' && value > schema.maximum) {
      walk.problems.push(`${label} must be at most ${schema.maximum}`);
    }
  }
  if (typeof value === 'string') {
    if (
      typeof schema.minLength === 'number' &&
      value.length < schema.minLength
    ) {
      walk.problems.push(
        schema.minLength === 1
          ? `${label} must not be empty`
          : `${label} must have at least ${schema.minLength} characters`,
      );
    }
    if (
      typeof schema.maxLength === 'number' &&
      value.length > schema.maxLength
    ) {
      walk.problems.push(
        `${label} must have at most ${schema.maxLength} characters`,
      );
    }
    if (typeof schema.pattern === 'string') {
      try {
        if (!new RegExp(schema.pattern).test(value)) {
          walk.problems.push(`${label} does not have the expected format`);
        }
      } catch {
        // an unusable pattern never fails a call
      }
    }
  }
  if (have === 'array' && schema.items) {
    return (value as unknown[]).map((item, index) =>
      check(item, schema.items, `${label}[${index}]`, walk),
    );
  }
  if (have === 'object' && (schema.properties || schema.required)) {
    return checkObject(value as Record<string, unknown>, schema, path, walk);
  }
  return value;
}

function checkObject(
  input: Record<string, unknown>,
  schema: JsonSchema,
  path: string,
  walk: Walk,
): Record<string, unknown> {
  const properties: Record<string, JsonSchema> = schema.properties ?? {};
  const required: string[] = schema.required ?? [];
  const out: Record<string, unknown> = {};
  const names = Object.keys(properties);
  for (const [key, raw] of Object.entries(input)) {
    const child = path ? `${path}.${key}` : key;
    let name = key;
    if (!(key in properties)) {
      // A near miss ("Query", "start_time" for "start") is the same argument.
      const match = names.find(
        candidate =>
          !(candidate in input) &&
          candidate.toLowerCase().replace(/[_-]/g, '') ===
            key.toLowerCase().replace(/[_-]/g, ''),
      );
      if (match) {
        walk.fixes.push(`${child} read as ${match}`);
        name = match;
      } else if (schema.additionalProperties === false) {
        walk.fixes.push(`unknown argument ${child} dropped`);
        continue;
      } else {
        out[key] = raw;
        continue;
      }
    }
    const propertySchema = properties[name];
    const isRequired = required.includes(name);
    if ((raw === null || raw === undefined) && !isRequired) {
      continue;
    }
    if (
      !isRequired &&
      typeof raw === 'string' &&
      raw.trim() === '' &&
      primaryType(propertySchema) !== 'string'
    ) {
      continue;
    }
    out[name] = check(
      raw,
      propertySchema,
      path ? `${path}.${name}` : name,
      walk,
    );
  }
  for (const name of required) {
    const value = out[name];
    if (value === undefined || value === null) {
      walk.problems.unshift(
        `missing required argument "${path ? `${path}.` : ''}${name}"`,
      );
    } else if (typeof value === 'string' && value.trim() === '') {
      walk.problems.unshift(
        `required argument "${path ? `${path}.` : ''}${name}" is empty`,
      );
    }
  }
  return out;
}

function describeType(schema: JsonSchema): string {
  const type = primaryType(schema) ?? 'a value';
  switch (type) {
    case 'string':
      return 'text';
    case 'integer':
      return 'a whole number';
    case 'number':
      return 'a number';
    case 'boolean':
      return 'true or false';
    case 'array':
      return 'a list';
    case 'object':
      return 'an object';
    default:
      return type;
  }
}

/** Validate (and gently coerce) tool arguments against the tool's schema. */
export function validateArguments(
  args: unknown,
  schema: JsonSchema,
): ValidationResult {
  const walk: Walk = {problems: [], fixes: []};
  if (typeOf(args) !== 'object') {
    return {
      ok: false,
      value: {},
      problems: ['the arguments are not a JSON object'],
      fixes: [],
    };
  }
  const value = checkObject(
    args as Record<string, unknown>,
    {type: 'object', ...schema},
    '',
    walk,
  );
  return {
    ok: walk.problems.length === 0,
    value,
    problems: [...new Set(walk.problems)],
    fixes: walk.fixes,
  };
}
