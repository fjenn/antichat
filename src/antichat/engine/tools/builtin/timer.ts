/**
 * Timer and alarm payload. The engine validates the request and returns a
 * `TimerCard`; scheduling the notification belongs to the native layer, which
 * reads the card from the tool result event. Works offline.
 */
import type {TimerCard} from '../cards';
import type {AntichatTool} from '../types';

const MAX_SECONDS = 7 * 24 * 3600;

/** "10 min", "1h30m", "90 seconds", "1:30" (m:ss), "2 hours" → seconds. */
export function parseDuration(input: string): number | null {
  const text = input.trim().toLowerCase();
  if (/^\d+(\.\d+)?$/.test(text)) {
    return Math.round(Number(text));
  }
  const clock = /^(\d{1,2}):(\d{2})(?::(\d{2}))?$/.exec(text);
  if (clock) {
    return clock[3]
      ? Number(clock[1]) * 3600 + Number(clock[2]) * 60 + Number(clock[3])
      : Number(clock[1]) * 60 + Number(clock[2]);
  }
  let total = 0;
  let matched = false;
  const pattern =
    /(\d+(?:\.\d+)?)\s*(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s|days?|d)\b/g;
  let match: RegExpExecArray | null;
  while ((match = pattern.exec(text)) !== null) {
    matched = true;
    const value = Number(match[1]);
    const unit = match[2][0];
    total +=
      value *
      (unit === 'h' ? 3600 : unit === 'm' ? 60 : unit === 'd' ? 86400 : 1);
  }
  return matched ? Math.round(total) : null;
}

export function formatDuration(seconds: number): string {
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const rest = seconds % 60;
  const parts: string[] = [];
  if (hours) {
    parts.push(`${hours} h`);
  }
  if (minutes) {
    parts.push(`${minutes} min`);
  }
  if (rest || parts.length === 0) {
    parts.push(`${rest} s`);
  }
  return parts.join(' ');
}

const pad = (value: number): string => String(value).padStart(2, '0');

const localIso = (date: Date): string =>
  `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;

export const setTimerTool: AntichatTool = {
  name: 'set_timer',
  description:
    'Start a countdown timer for a duration, or set an alarm for a clock time today or tomorrow.',
  parameters: {
    type: 'object',
    properties: {
      duration: {
        type: 'string',
        description: 'Countdown length, e.g. "10 min", "1h 30m", "45 seconds"',
      },
      at: {
        type: 'string',
        description: 'Alarm time as HH:MM (24 h), instead of duration',
      },
      label: {type: 'string', description: 'What the timer is for'},
    },
    additionalProperties: false,
  },
  kind: 'local',
  tier: 'always',
  keywords: ['timer', 'alarm', 'countdown', 'remind', 'stopwatch', 'wake'],
  triggers: ['alarm', 'countdown', 'wecker'],
  timeoutMs: 2000,
  example: {duration: '10 min', label: 'pasta'},
  normalize: args => {
    const out: Record<string, unknown> = {...args};
    for (const [key, factor] of [
      ['seconds', 1],
      ['duration_seconds', 1],
      ['minutes', 60],
      ['hours', 3600],
    ] as const) {
      if (typeof out[key] === 'number' && out.duration === undefined) {
        out.duration = String((out[key] as number) * factor);
      }
      delete out[key];
    }
    if (typeof out.duration === 'number') {
      out.duration = String(out.duration);
    }
    if (out.time !== undefined && out.at === undefined) {
      out.at = out.time;
    }
    delete out.time;
    return out;
  },
  async execute(args, context) {
    const now = context.now;
    const label =
      typeof args.label === 'string' && args.label.trim()
        ? args.label.trim()
        : undefined;
    if (args.at) {
      const match = /^(\d{1,2})[:.](\d{2})\s*(am|pm)?$/i.exec(
        String(args.at).trim(),
      );
      if (!match) {
        return {
          text: 'set_timer: "at" must be a time such as 07:30.',
          isError: true,
        };
      }
      let hour = Number(match[1]);
      const minute = Number(match[2]);
      const half = match[3]?.toLowerCase();
      if (half === 'pm' && hour < 12) {
        hour += 12;
      }
      if (half === 'am' && hour === 12) {
        hour = 0;
      }
      if (hour > 23 || minute > 59) {
        return {
          text: 'set_timer: that is not a valid clock time.',
          isError: true,
        };
      }
      const fires = new Date(
        now.getFullYear(),
        now.getMonth(),
        now.getDate(),
        hour,
        minute,
        0,
      );
      const tomorrow = fires.getTime() <= now.getTime();
      if (tomorrow) {
        fires.setDate(fires.getDate() + 1);
      }
      const card: TimerCard = {
        type: 'timer',
        kind: 'alarm',
        label,
        firesAt: localIso(fires),
        createdAt: localIso(now),
      };
      return {
        text: `Alarm set for ${pad(hour)}:${pad(minute)} ${tomorrow ? 'tomorrow' : 'today'}${label ? ` (${label})` : ''}.`,
        card,
      };
    }
    const seconds = args.duration ? parseDuration(String(args.duration)) : null;
    if (!seconds || seconds <= 0) {
      return {
        text: 'set_timer: give a duration such as "10 min", or an alarm time in "at".',
        isError: true,
      };
    }
    if (seconds > MAX_SECONDS) {
      return {text: 'set_timer: the longest timer is 7 days.', isError: true};
    }
    const card: TimerCard = {
      type: 'timer',
      kind: 'timer',
      label,
      durationSeconds: seconds,
      firesAt: localIso(new Date(now.getTime() + seconds * 1000)),
      createdAt: localIso(now),
    };
    return {
      text: `Timer started: ${formatDuration(seconds)}${label ? ` (${label})` : ''}.`,
      card,
    };
  },
};
