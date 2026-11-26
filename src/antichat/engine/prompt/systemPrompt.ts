/**
 * System-prompt builder for small on-device models (H7).
 *
 * Rules it enforces:
 *  - Short. The base is one identity sentence and one style paragraph, well
 *    under 200 tokens, so it fits a 4k window with room to spare.
 *  - Stable prefix first. Everything that never changes during a chat comes
 *    first, byte for byte the same on every request, so llama.cpp reuses the
 *    KV cache. The date (day granularity) and other per-chat blocks sit at the
 *    end of the system message; anything per-turn rides on the newest user
 *    message instead (see `SystemSlot`).
 *
 * Base wording: AntiChat Mac `prompts/base.txt`, with the reusable lines the
 * ChatGPT audit quotes (docs/research/01 §4.1), tuned on Gemma 4 E2B,
 * Qwen3.5 and LFM3 (docs/antichat/m7-prompt-eval.md).
 */
import {familyProfile, type ModelFamily} from './modelFamily';
import {
  personalizationBlocks,
  type PersonalizationSettings,
} from './personalization';
import type {DeviceClass, SystemBlock} from './types';

export const APP_NAME = 'AntiChat';

export const BASE_IDENTITY = `You are ${APP_NAME}, a private AI assistant that runs entirely on the user's phone. You help with anything: questions, writing, analysis, coding, planning and conversation.`;

export const BASE_STYLE =
  'Answer directly and clearly, in the language the user writes in. Keep replies short enough to read on a phone unless the task needs length. Write in natural, compact paragraphs; use Markdown when it helps, with at most one list per reply unless the user asks for structure, and write tables as plain Markdown tables, never inside a code block. Be warm but honest, without flattery, and do not end with offers of further help. If you are not sure about a fact, say so instead of guessing.';

/** Mac `ToolSelection.clause`, verbatim. Added only when tools are offered. */
export const TOOL_USE_CLAUSE =
  'Call a tool only when the request needs what that tool does, or when the user asks you to use it; then call it instead of writing out what it would do. For a tool that runs code, run the code with it rather than only showing the code. Otherwise answer directly without calling any tool.';

const WEEKDAYS = [
  'Sunday',
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
];

const pad = (value: number): string => String(value).padStart(2, '0');

/**
 * `Current date: 2026-11-24 (Tuesday).` — the device's calendar day. Fixed
 * English wording, so the bytes change once a day and never with the minute.
 */
export function dateLine(now: Date, timeZone?: string): string {
  const date = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
  const zone = timeZone ? `, time zone ${timeZone}` : '';
  return `Current date: ${date} (${WEEKDAYS[now.getDay()]})${zone}.`;
}

/** `Current local time: 14:05.` — per-minute, so it is turn context only. */
export function timeLine(now: Date): string {
  return `Current local time: ${pad(now.getHours())}:${pad(now.getMinutes())}.`;
}

const CLOCK_WORDS =
  /\b(?:time|o'?clock|now|tonight|this (?:morning|afternoon|evening)|how long until|minutes?|hours?|uhr|uhrzeit|sp[aä]t|jetzt|heute abend|hora|ahora|heure|maintenant|ora|adesso|agora|tijd|nu)\b|何時|今何|现在|現在|几点|幾點|몇 시|지금/i;

/** Does this message plausibly depend on the time of day? */
export function needsClock(userText: string): boolean {
  return CLOCK_WORDS.test(userText);
}

export interface SystemPromptOptions {
  family?: ModelFamily;
  deviceClass?: DeviceClass;
  personalization?: PersonalizationSettings | null;
  /** e.g. "January 2026". Left out when the model's cutoff is not known. */
  knowledgeCutoff?: string;
  /** True when the request offers tools. */
  hasTools?: boolean | 'whenOffered';
  now: Date;
  timeZone?: string;
}

/** The blocks this module owns. Other providers add theirs to the registry. */
export function buildSystemBlocks(options: SystemPromptOptions): SystemBlock[] {
  const family = options.family ?? 'generic';
  const blocks: SystemBlock[] = [
    {
      id: 'base',
      slot: 'stable',
      order: 10,
      text: `${BASE_IDENTITY}\n\n${BASE_STYLE}`,
    },
  ];
  const addendum = familyProfile(family).systemAddendum;
  if (addendum) {
    blocks.push({id: 'family', slot: 'stable', order: 15, text: addendum});
  }
  if (options.knowledgeCutoff) {
    blocks.push({
      id: 'cutoff',
      slot: 'stable',
      order: 20,
      text: `Your knowledge ends around ${options.knowledgeCutoff}; for anything newer, rely on what the user or a tool gives you and say when you may be out of date.`,
    });
  }
  blocks.push(
    ...personalizationBlocks(options.personalization, options.deviceClass),
  );
  if (options.hasTools) {
    blocks.push({
      id: 'tool-use',
      slot: 'stable',
      order: 80,
      text: TOOL_USE_CLAUSE,
      // 'whenOffered': decided by the seam once every provider has added
      // its tools (memory, files), not by the pal's own list.
      ...(options.hasTools === 'whenOffered' ? {when: 'tools' as const} : {}),
    });
  }
  blocks.push({
    id: 'date',
    slot: 'session',
    order: 10,
    text: dateLine(options.now, options.timeZone),
  });
  return blocks;
}

/** The finished system text when only this module contributes (tests, eval). */
export function buildSystemPrompt(options: SystemPromptOptions): string {
  const blocks = buildSystemBlocks(options);
  const text = (slot: SystemBlock['slot']) =>
    blocks
      .filter(block => block.slot === slot)
      .sort((a, b) => (a.order ?? 100) - (b.order ?? 100))
      .map(block => block.text);
  return [...text('stable'), ...text('session')].join('\n\n');
}
