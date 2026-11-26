/**
 * Follow-up suggestions (H10): up to three things the user might ask next,
 * generated only when the phone is idle after a reply and only on device
 * classes that can afford it (C and above; the gap analysis' device rule).
 *
 * ChatGPT's own prompt was never found, so this one is ours, tuned on the
 * real models (docs/antichat/m7-prompt-eval.md). It is always a stand-alone
 * prompt: asked as one more turn of the chat, Gemma 4 E2B and Qwen3.5
 * suggest unrelated topics. The answer is constrained
 * to JSON by the engine's grammar; the parser still accepts plain lines,
 * because a remote engine may ignore the schema.
 */
import type {CompletionEngine} from '../../../utils/completionTypes';
import type {ModelFamily} from './modelFamily';
import {detectDominantScript} from './hygiene/normalizeModelText';
import {guessLatinLanguage} from './title';
import type {ChatMessage, DeviceClass} from './types';
import {clipText, runUtilityCompletion} from './utility';

export const FOLLOWUP_COUNT = 3;
export const FOLLOWUP_MAX_CHARS = 64;
export const FOLLOWUP_MAX_TOKENS = 96;

export const FOLLOWUP_SYSTEM_PROMPT = `You suggest what the user could ask next. Given the user's last message and the assistant's reply, write ${FOLLOWUP_COUNT} short follow-up questions or requests the USER might send next. Write them from the user's point of view, in the user's language, each under 10 words, each about a different angle, none repeating what was already asked. Reply with JSON only: {"suggestions": ["...", "...", "..."]}`;

export const FOLLOWUP_SCHEMA = {
  type: 'object',
  properties: {
    suggestions: {
      type: 'array',
      items: {type: 'string'},
      minItems: FOLLOWUP_COUNT,
      maxItems: FOLLOWUP_COUNT,
    },
  },
  required: ['suggestions'],
  additionalProperties: false,
};

/** Follow-ups are generated on class C and D only. */
export function followUpsAllowed(deviceClass: DeviceClass): boolean {
  return deviceClass === 'C' || deviceClass === 'D';
}

const LIST_MARKER = /^\s*(?:\d+[.)]|[-*•])\s*/;
const QUOTES = /^["'“”‘’«»]+|["'“”‘’«»]+$/g;

// The assistant offering something, not the user asking.
const ASSISTANT_VOICE =
  /^(?:would you like|do you (?:want|need)|should i\b|shall i\b|can i help|let me know|möchtest du|möchten sie|soll ich|quieres que|¿quieres que|voulez-vous|veux-tu|vuoi che)/i;

/** Same script as the user, and not English for a clearly non-English chat. */
const inUserLanguage = (text: string, userMessage: string): boolean => {
  if (!userMessage.trim()) {
    return true;
  }
  const userScript = detectDominantScript(userMessage);
  if (userScript !== 'latin' && userScript !== 'other') {
    return detectDominantScript(text) === userScript;
  }
  const userLanguage = guessLatinLanguage(userMessage);
  return !(
    userLanguage &&
    userLanguage !== 'en' &&
    guessLatinLanguage(text) === 'en'
  );
};

const normalise = (text: string): string =>
  text
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, ' ')
    .trim();

const extractCandidates = (raw: string): string[] => {
  const start = raw.indexOf('{');
  const end = raw.lastIndexOf('}');
  if (start !== -1 && end > start) {
    try {
      const parsed = JSON.parse(raw.slice(start, end + 1));
      const list = Array.isArray(parsed)
        ? parsed
        : (parsed.suggestions ?? parsed.questions ?? parsed.follow_ups);
      if (Array.isArray(list)) {
        return list.filter(item => typeof item === 'string');
      }
    } catch {
      // fall through to the line parser
    }
  }
  const arrayStart = raw.indexOf('[');
  const arrayEnd = raw.lastIndexOf(']');
  if (arrayStart !== -1 && arrayEnd > arrayStart) {
    try {
      const parsed = JSON.parse(raw.slice(arrayStart, arrayEnd + 1));
      if (Array.isArray(parsed)) {
        return parsed.filter(item => typeof item === 'string');
      }
    } catch {
      // fall through
    }
  }
  return raw
    .split(/\r?\n/)
    .filter(line => LIST_MARKER.test(line))
    .map(line => line.replace(LIST_MARKER, ''));
};

/** Parse and clean model output into at most three usable suggestions. */
export function parseFollowUps(raw: string, userMessage = ''): string[] {
  const seen = new Set<string>([normalise(userMessage)]);
  const out: string[] = [];
  for (const candidate of extractCandidates(raw)) {
    const text = candidate
      .replace(LIST_MARKER, '')
      .replace(/\s+/g, ' ')
      .trim()
      .replace(QUOTES, '')
      .trim();
    const key = normalise(text);
    if (
      !key ||
      text.length < 4 ||
      text.length > FOLLOWUP_MAX_CHARS ||
      seen.has(key) ||
      /[<>{}|]/.test(text) ||
      ASSISTANT_VOICE.test(text) ||
      !inUserLanguage(text, userMessage)
    ) {
      continue;
    }
    seen.add(key);
    out.push(text);
    if (out.length === FOLLOWUP_COUNT) {
      break;
    }
  }
  return out;
}

export interface FollowUpRequest {
  engine: CompletionEngine;
  userMessage: string;
  assistantReply: string;
  family?: ModelFamily;
  signal?: AbortSignal;
  timeoutMs?: number;
}

export function buildFollowUpMessages(request: FollowUpRequest): ChatMessage[] {
  return [
    {role: 'system', content: FOLLOWUP_SYSTEM_PROMPT},
    {
      role: 'user',
      content: `User message:\n${clipText(request.userMessage, 500)}\n\nAssistant reply:\n${clipText(request.assistantReply, 900)}`,
    },
  ];
}

/** Generate follow-ups. Returns [] rather than fewer than two suggestions. */
export async function generateFollowUps(
  request: FollowUpRequest,
): Promise<string[]> {
  if (!request.userMessage.trim() || !request.assistantReply.trim()) {
    return [];
  }
  const result = await runUtilityCompletion({
    engine: request.engine,
    messages: buildFollowUpMessages(request),
    maxTokens: FOLLOWUP_MAX_TOKENS,
    temperature: 0.5,
    family: request.family,
    jsonSchema: {name: 'follow_ups', schema: FOLLOWUP_SCHEMA},
    signal: request.signal,
    timeoutMs: request.timeoutMs ?? 12000,
  });
  if (!result) {
    return [];
  }
  const suggestions = parseFollowUps(result.text, request.userMessage);
  return suggestions.length >= 2 ? suggestions : [];
}
