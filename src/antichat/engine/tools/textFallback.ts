/**
 * Text-fallback parsing: tool calls a model printed as text instead of
 * through the template's call channel. Small models do this when the lazy
 * grammar does not trigger (a stray space before the marker, a format from
 * another model family, a call wrapped in a code fence).
 *
 * Formats (design from Off Grid's `generationToolLoop.ts`, MIT, extended for
 * LFM's Pythonic calls):
 *   <tool_call>{"name": "x", "arguments": {…}}</tool_call>     Hermes / Qwen
 *   <tool_call>x({…})</tool_call>, <tool_call>x{…}</tool_call>
 *   <function=x><parameter=k>v</parameter></function>           Qwen XML
 *   <|tool_call>call:x{k:<|"|>v<|"|>}<tool_call|>                Gemma 4
 *   <|tool_call_start|>[x(k="v", n=3)]<|tool_call_end|>          LFM
 *   ```json {"name": "x", "arguments": {…}} ```                  fenced
 *   {"name": "x", "arguments"|"parameters": {…}}                 bare JSON
 *   {"tool": "x", "args": {…}} / {"function": {"name": …}}       variants
 *
 * A bare-JSON or Pythonic call only counts when `x` is an offered tool, so
 * an answer that merely shows JSON is never mistaken for a call.
 */
import {parseArguments} from './repair';
import type {ToolCall} from './types';

export interface TextFallbackResult {
  calls: ToolCall[];
  /** The text with the call markup removed (what the user may see). */
  text: string;
}

let counter = 0;
const nextId = (): string =>
  `text-call-${Date.now().toString(36)}-${counter++}`;

const call = (name: string, args: unknown): ToolCall => ({
  id: nextId(),
  name,
  argumentsText: typeof args === 'string' ? args : JSON.stringify(args ?? {}),
});

function fromObject(parsed: any): {name: string; args: unknown} | null {
  if (!parsed || typeof parsed !== 'object') {
    return null;
  }
  const fn = parsed.function;
  const name =
    (typeof parsed.name === 'string' && parsed.name) ||
    (typeof parsed.tool === 'string' && parsed.tool) ||
    (typeof parsed.tool_name === 'string' && parsed.tool_name) ||
    (typeof fn === 'string' && fn) ||
    (fn && typeof fn.name === 'string' && fn.name) ||
    '';
  if (!name) {
    return null;
  }
  const args =
    parsed.arguments ??
    parsed.parameters ??
    parsed.args ??
    parsed.input ??
    (fn && typeof fn === 'object' ? fn.arguments : undefined) ??
    {};
  return {name, args};
}

function parseJsonCall(body: string): {name: string; args: unknown} | null {
  const parsed = parseArguments(body);
  return parsed.ok ? fromObject(parsed.value) : null;
}

/** `k:<|"|>v<|"|>, n:3` — Gemma 4's own argument syntax. */
function parseGemmaArgs(body: string): Record<string, unknown> {
  const json = body
    .replace(/<\|"\|>/g, '"')
    .replace(/([{,]\s*)([A-Za-z_][\w-]*)\s*:/g, '$1"$2":');
  const parsed = parseArguments(json);
  return parsed.ok ? parsed.value : {};
}

/** `k="v", n=3, flag=True, items=["a", "b"]` — a Python call's arguments. */
export function parsePythonArgs(body: string): Record<string, unknown> {
  const args: Record<string, unknown> = {};
  let index = 0;
  const skipSpace = () => {
    while (index < body.length && /[\s,]/.test(body[index])) {
      index++;
    }
  };
  while (index < body.length) {
    skipSpace();
    const key = /^[A-Za-z_]\w*/.exec(body.slice(index));
    if (!key) {
      break;
    }
    index += key[0].length;
    skipSpace();
    if (body[index] !== '=' && body[index] !== ':') {
      break;
    }
    index++;
    skipSpace();
    const start = index;
    const quote = body[index];
    if (quote === '"' || quote === "'") {
      index++;
      while (index < body.length && body[index] !== quote) {
        index += body[index] === '\\' ? 2 : 1;
      }
      index++;
      const inner = body.slice(start + 1, index - 1);
      args[key[0]] = inner.replace(/\\(["'\\])/g, '$1').replace(/\\n/g, '\n');
      continue;
    }
    let depth = 0;
    let inString: string | null = null;
    while (index < body.length) {
      const char = body[index];
      if (inString) {
        if (char === '\\') {
          index++;
        } else if (char === inString) {
          inString = null;
        }
      } else if (char === '"' || char === "'") {
        inString = char;
      } else if (char === '[' || char === '{' || char === '(') {
        depth++;
      } else if (char === ']' || char === '}' || char === ')') {
        depth--;
      } else if (char === ',' && depth === 0) {
        break;
      }
      index++;
    }
    const raw = body.slice(start, index).trim();
    if (/^(True|False)$/.test(raw)) {
      args[key[0]] = raw === 'True';
    } else if (raw === 'None') {
      args[key[0]] = null;
    } else if (/^-?\d+(\.\d+)?$/.test(raw)) {
      args[key[0]] = Number(raw);
    } else {
      const parsed = parseArguments(`{"v": ${raw.replace(/'/g, '"')}}`);
      args[key[0]] = parsed.ok ? parsed.value.v : raw;
    }
  }
  return args;
}

function parseXmlFunction(body: string): {name: string; args: unknown} | null {
  const fn = /<function=([\w.-]+)>/.exec(body);
  if (!fn) {
    return null;
  }
  const args: Record<string, string> = {};
  const pattern =
    /<parameter=([\w.-]+)>([\s\S]*?)(?=<\/parameter>|<parameter=|<\/function>|$)/g;
  let match: RegExpExecArray | null;
  while ((match = pattern.exec(body)) !== null) {
    args[match[1]] = match[2].trim();
  }
  return {name: fn[1], args};
}

function parseBody(body: string): {name: string; args: unknown} | null {
  const trimmed = body.trim();
  const json = parseJsonCall(trimmed);
  if (json) {
    return json;
  }
  const xml = parseXmlFunction(trimmed);
  if (xml) {
    return xml;
  }
  const wrapped = /^([\w.-]+)\s*\(?(\{[\s\S]*\})\)?$/.exec(trimmed);
  if (wrapped) {
    const parsed = parseArguments(wrapped[2]);
    if (parsed.ok) {
      return {name: wrapped[1], args: parsed.value};
    }
  }
  const python = /^([\w.-]+)\s*\(([\s\S]*)\)$/.exec(trimmed);
  if (python) {
    return {name: python[1], args: parsePythonArgs(python[2])};
  }
  if (/^[\w.-]+$/.test(trimmed)) {
    return {name: trimmed, args: {}};
  }
  return null;
}

/** Any call markup at all? Cheap test before the full parse. */
export function hasToolCallMarkup(text: string): boolean {
  return /<tool_call|<\|tool_call|<function=|<\|tool_call_start\|>|\[TOOL_CALLS?\]|<start_function_call>/i.test(
    text,
  );
}

const MARKUP_RESIDUE =
  /<\/?tool_call>|<\|tool_call>|<tool_call\|>|<\|tool_call_start\|>|<\|tool_call_end\|>|<\/?function[^>]*>|<\/?parameter[^>]*>|\[TOOL_CALLS?\]|<start_function_call>|<end_function_call>|<\|tool_response>|<tool_response\|>|<\/?tool_response>/gi;

/**
 * Parse calls from model text. `known` is the set of offered tool names;
 * unknown names are still returned for tagged formats (so the repair prompt
 * can name the real tools) but never for untagged ones.
 */
export function parseToolCallsFromText(
  input: string,
  known: readonly string[] = [],
): TextFallbackResult {
  const calls: ToolCall[] = [];
  let text = input ?? '';
  const isKnown = (name: string) => known.length === 0 || known.includes(name);

  const take = (pattern: RegExp, read: (match: RegExpExecArray) => void) => {
    text = text.replace(pattern, (...parts) => {
      read(parts.slice(0, -2) as unknown as RegExpExecArray);
      return ' ';
    });
  };

  // Gemma 4.
  take(
    /(?:<\|tool_call>|<tool_call:)\s*(?:call:)?([\w.-]+)\s*(\{[\s\S]*?\})?\s*(?:<tool_call\|>|<\/tool_call>|$)/g,
    match => {
      calls.push(call(match[1], match[2] ? parseGemmaArgs(match[2]) : {}));
    },
  );

  // LFM: a Python list of calls.
  take(/<\|tool_call_start\|>([\s\S]*?)(?:<\|tool_call_end\|>|$)/g, match => {
    const inner = match[1].trim().replace(/^\[/, '').replace(/\]$/, '');
    const pattern =
      /([\w.-]+)\s*\(((?:[^()"']|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\([^()]*\))*)\)/g;
    let found: RegExpExecArray | null;
    let any = false;
    while ((found = pattern.exec(inner)) !== null) {
      any = true;
      calls.push(call(found[1], parsePythonArgs(found[2])));
    }
    if (!any) {
      const parsed = parseBody(inner);
      if (parsed) {
        calls.push(call(parsed.name, parsed.args));
      }
    }
  });

  // Hermes / Qwen, closed or cut off at the end of the output.
  take(/<tool_call>([\s\S]*?)(?:<\/tool_call>|$)/g, match => {
    const parsed = parseBody(match[1]);
    if (parsed) {
      calls.push(call(parsed.name, parsed.args));
    }
  });

  // Qwen XML without the wrapper.
  take(/<function=[\w.-]+>[\s\S]*?(?:<\/function>|$)/g, match => {
    const parsed = parseXmlFunction(match[0]);
    if (parsed) {
      calls.push(call(parsed.name, parsed.args));
    }
  });

  // Mistral-style list.
  take(/\[TOOL_CALLS?\]\s*(\[[\s\S]*?\])\s*$/g, match => {
    try {
      const list = JSON.parse(match[1]);
      for (const item of Array.isArray(list) ? list : []) {
        const parsed = fromObject(item);
        if (parsed) {
          calls.push(call(parsed.name, parsed.args));
        }
      }
    } catch {
      // not a call list
    }
  });

  if (calls.length === 0 && known.length > 0) {
    // Fenced JSON, then a bare JSON object: only for offered tools, and only
    // when the JSON is (nearly) the whole message.
    const fenced = /```(?:json|tool_call|tool)?\s*(\{[\s\S]*?\})\s*```/.exec(
      text,
    );
    const candidate = fenced ? fenced[1] : firstJsonObject(text);
    if (candidate) {
      const parsed = parseJsonCall(candidate);
      const rest = text.replace(fenced ? fenced[0] : candidate, '').trim();
      if (parsed && isKnown(parsed.name) && rest.length < 80) {
        calls.push(call(parsed.name, parsed.args));
        text = rest;
      }
    }
  }

  if (calls.length === 0 && known.length > 0) {
    // Pythonic call on its own line: web_search(query="…")
    const line = /^\s*\[?\s*([\w.-]+)\(([^\n]*)\)\s*\]?\s*$/m.exec(text);
    if (
      line &&
      known.includes(line[1]) &&
      text.trim().length - line[0].trim().length < 80
    ) {
      calls.push(call(line[1], parsePythonArgs(line[2])));
      text = text.replace(line[0], ' ');
    }
  }

  return {
    calls,
    text: text
      .replace(MARKUP_RESIDUE, ' ')
      .replace(/[ \t]{2,}/g, ' ')
      .trim(),
  };
}

function firstJsonObject(text: string): string | null {
  const start = text.indexOf('{');
  if (start === -1) {
    return null;
  }
  let depth = 0;
  let inString = false;
  for (let i = start; i < text.length; i++) {
    const char = text[i];
    if (inString) {
      if (char === '\\') {
        i++;
      } else if (char === '"') {
        inString = false;
      }
    } else if (char === '"') {
      inString = true;
    } else if (char === '{') {
      depth++;
    } else if (char === '}') {
      depth--;
      if (depth === 0) {
        return text.slice(start, i + 1);
      }
    }
  }
  return text.slice(start);
}
