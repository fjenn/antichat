/**
 * Date and time: the clock, date arithmetic, weekdays and differences.
 * Small models get dates wrong more than anything else in tool arguments
 * (measured: "Friday" → the wrong day, "next week" → this week), so this file
 * also builds the short date table the harness adds to a turn that mentions
 * relative dates. Works offline.
 */
import type {DateTimeCard} from '../cards';
import type {AntichatTool, ToolContext} from '../types';

const WEEKDAYS = [
  'Sunday',
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
];
const MONTHS = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

const pad = (value: number): string => String(value).padStart(2, '0');

export const isoDate = (date: Date): string =>
  `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;

export const longDate = (date: Date): string =>
  `${WEEKDAYS[date.getDay()]}, ${date.getDate()} ${MONTHS[date.getMonth()]} ${date.getFullYear()}`;

const startOfDay = (date: Date): Date =>
  new Date(date.getFullYear(), date.getMonth(), date.getDate());

export const addDays = (date: Date, days: number): Date =>
  new Date(date.getFullYear(), date.getMonth(), date.getDate() + days);

export function addToDate(
  date: Date,
  amount: number,
  unit: 'days' | 'weeks' | 'months' | 'years',
): Date {
  switch (unit) {
    case 'weeks':
      return addDays(date, amount * 7);
    case 'months': {
      const target = new Date(date.getFullYear(), date.getMonth() + amount, 1);
      const last = new Date(
        target.getFullYear(),
        target.getMonth() + 1,
        0,
      ).getDate();
      return new Date(
        target.getFullYear(),
        target.getMonth(),
        Math.min(date.getDate(), last),
      );
    }
    case 'years':
      return addToDate(date, amount * 12, 'months');
    default:
      return addDays(date, amount);
  }
}

export const daysBetween = (from: Date, to: Date): number =>
  Math.round(
    (startOfDay(to).getTime() - startOfDay(from).getTime()) / 86400000,
  );

/**
 * Parse a date the model or user wrote: ISO, "today", "tomorrow",
 * "next friday", "friday", "in 3 days", "25 December [2026]", "Dec 25".
 */
export function parseDate(input: string, now: Date): Date | null {
  const text = input
    .trim()
    .toLowerCase()
    .replace(/,/g, ' ')
    .replace(/\s+/g, ' ');
  if (!text) {
    return null;
  }
  const iso = /^(\d{4})-(\d{1,2})-(\d{1,2})/.exec(text);
  if (iso) {
    return new Date(Number(iso[1]), Number(iso[2]) - 1, Number(iso[3]));
  }
  if (text === 'today' || text === 'now') {
    return startOfDay(now);
  }
  if (text === 'tomorrow') {
    return addDays(now, 1);
  }
  if (text === 'yesterday') {
    return addDays(now, -1);
  }
  if (text === 'day after tomorrow' || text === 'the day after tomorrow') {
    return addDays(now, 2);
  }
  const relative = /^in (\d+) (day|week|month|year)s?$/.exec(text);
  if (relative) {
    return addToDate(
      startOfDay(now),
      Number(relative[1]),
      `${relative[2]}s` as 'days',
    );
  }
  const ago = /^(\d+) (day|week|month|year)s? ago$/.exec(text);
  if (ago) {
    return addToDate(startOfDay(now), -Number(ago[1]), `${ago[2]}s` as 'days');
  }
  const weekday =
    /^(next |this |on |last )?(sun|mon|tue|tues|wed|thu|thur|thurs|fri|sat)[a-z]*$/.exec(
      text,
    );
  if (weekday) {
    const index = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'].indexOf(
      weekday[2].slice(0, 3),
    );
    const today = now.getDay();
    if (weekday[1] === 'last ') {
      const back = (today - index + 7) % 7 || 7;
      return addDays(now, -back);
    }
    let ahead = (index - today + 7) % 7;
    if (ahead === 0) {
      ahead = 7;
    }
    // "next friday" said on a Tuesday is commonly the Friday of next week.
    if (weekday[1] === 'next ' && ahead < 7 && index > today) {
      ahead += 7;
    }
    return addDays(now, ahead);
  }
  const months = MONTHS.map(month => month.toLowerCase().slice(0, 3));
  const dayMonth =
    /^(\d{1,2})(?:st|nd|rd|th)? (?:of )?([a-z]{3})[a-z]*(?: (\d{4}))?$/.exec(
      text,
    );
  const monthDay =
    /^([a-z]{3})[a-z]* (\d{1,2})(?:st|nd|rd|th)?(?: (\d{4}))?$/.exec(text);
  const pick = dayMonth
    ? {
        day: Number(dayMonth[1]),
        month: months.indexOf(dayMonth[2]),
        year: dayMonth[3],
      }
    : monthDay
      ? {
          day: Number(monthDay[2]),
          month: months.indexOf(monthDay[1]),
          year: monthDay[3],
        }
      : null;
  if (pick && pick.month >= 0) {
    if (pick.year) {
      return new Date(Number(pick.year), pick.month, pick.day);
    }
    const thisYear = new Date(now.getFullYear(), pick.month, pick.day);
    return thisYear < startOfDay(now)
      ? new Date(now.getFullYear() + 1, pick.month, pick.day)
      : thisYear;
  }
  const numeric = /^(\d{1,2})[./](\d{1,2})[./](\d{4})$/.exec(text);
  if (numeric) {
    // Day first: the unambiguous reading outside the US.
    return new Date(
      Number(numeric[3]),
      Number(numeric[2]) - 1,
      Number(numeric[1]),
    );
  }
  return null;
}

/** Does the message refer to a relative date or a weekday? */
export const RELATIVE_DATE =
  /\b(today|tonight|tomorrow|yesterday|this (?:week|weekend|month|morning|afternoon|evening)|next (?:week|month|mon|tue|wed|thu|fri|sat|sun)[a-z]*|last (?:week|weekend|month)|(?:mon|tues|wednes|thurs|fri|satur|sun)day|in \d+ (?:days?|weeks?)|heute|morgen|übermorgen|gestern|nächste[nr]? (?:woche|monat)|(?:mon|diens|donners|frei|sams|sonn)tag|mittwoch|mañana|hoy|ayer|demain|aujourd'hui|hier)\b/i;

const SHORT = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

/**
 * `Dates: today Tue 2026-11-24; tomorrow Wed 2026-11-25; Thu 2026-11-26; …;
 * next week: Mon 2026-11-30 … Sun 2026-12-06.` Rides on the newest user
 * message (turn context), never in the cached system prompt.
 */
export function upcomingDatesLine(now: Date): string {
  const today = startOfDay(now);
  const parts = [
    `today ${SHORT[today.getDay()]} ${isoDate(today)}`,
    `tomorrow ${SHORT[addDays(today, 1).getDay()]} ${isoDate(addDays(today, 1))}`,
  ];
  // Rest of this week (through Sunday), then next week Monday–Sunday.
  const untilSunday = (7 - today.getDay()) % 7;
  for (let offset = 2; offset <= untilSunday; offset++) {
    const day = addDays(today, offset);
    parts.push(`${SHORT[day.getDay()]} ${isoDate(day)}`);
  }
  const nextMonday = addDays(today, untilSunday + 1);
  const next: string[] = [];
  for (let offset = 0; offset < 7; offset++) {
    const day = addDays(nextMonday, offset);
    next.push(`${SHORT[day.getDay()]} ${isoDate(day)}`);
  }
  const yesterday = addDays(today, -1);
  return `Dates: yesterday ${SHORT[yesterday.getDay()]} ${isoDate(yesterday)}; ${parts.join('; ')}; next week: ${next.join(', ')}. "This week" started Mon ${isoDate(addDays(today, -((today.getDay() + 6) % 7)))}.`;
}

function timeIn(now: Date, timeZone?: string): {time: string; zone?: string} {
  if (timeZone) {
    try {
      const time = new Intl.DateTimeFormat('en-GB', {
        hour: '2-digit',
        minute: '2-digit',
        hour12: false,
        timeZone,
      }).format(now);
      return {time, zone: timeZone};
    } catch {
      // unknown zone: fall back to the device clock
    }
  }
  return {time: `${pad(now.getHours())}:${pad(now.getMinutes())}`};
}

function dateIn(now: Date, timeZone?: string): Date {
  if (!timeZone) {
    return now;
  }
  try {
    const parts = new Intl.DateTimeFormat('en-CA', {
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      timeZone,
    }).formatToParts(now);
    const get = (type: string) =>
      Number(parts.find(part => part.type === type)?.value);
    return new Date(
      get('year'),
      get('month') - 1,
      get('day'),
      now.getHours(),
      now.getMinutes(),
    );
  } catch {
    return now;
  }
}

export const dateTimeTool: AntichatTool = {
  name: 'date_time',
  description:
    'Current date and time, date arithmetic, days between two dates, or the weekday of a date.',
  parameters: {
    type: 'object',
    properties: {
      action: {type: 'string', enum: ['now', 'add', 'difference', 'weekday']},
      date: {type: 'string', description: 'YYYY-MM-DD or "today"'},
      amount: {
        type: 'integer',
        description: 'Units to add; negative subtracts',
      },
      unit: {type: 'string', enum: ['days', 'weeks', 'months', 'years']},
      other_date: {type: 'string', description: 'Second date for difference'},
      time_zone: {type: 'string', description: 'IANA zone, e.g. "Asia/Tokyo"'},
    },
    required: ['action'],
    additionalProperties: false,
  },
  kind: 'local',
  tier: 'always',
  keywords: [
    'date',
    'time',
    'clock',
    'weekday',
    'days until',
    'countdown',
    'calendar',
    'age',
  ],
  timeoutMs: 2000,
  example: {action: 'add', date: 'today', amount: 10, unit: 'days'},
  normalize: args => {
    const out = {...args};
    if (!out.action) {
      out.action = out.other_date
        ? 'difference'
        : out.amount !== undefined
          ? 'add'
          : out.date
            ? 'weekday'
            : 'now';
    }
    if (typeof out.unit === 'string' && !out.unit.endsWith('s')) {
      out.unit = `${out.unit}s`;
    }
    return out;
  },
  async execute(args, context: ToolContext) {
    const now = context.now;
    const fail = (message: string) => ({
      text: `date_time: ${message}.`,
      isError: true,
    });
    const read = (value: unknown, fallback?: Date): Date | null =>
      value === undefined || value === null || value === ''
        ? (fallback ?? null)
        : parseDate(String(value), now);

    if (args.action === 'now') {
      const zone = (args.time_zone as string | undefined) ?? context.timeZone;
      const local = args.time_zone ? dateIn(now, zone) : now;
      const {time, zone: usedZone} = timeIn(now, zone);
      const card: DateTimeCard = {
        type: 'datetime',
        iso: `${isoDate(local)}T${time}`,
        timeZone: usedZone,
        dateText: longDate(local),
        timeText: time,
      };
      return {
        text: `It is ${longDate(local)}, ${time}${usedZone ? ` (${usedZone})` : ''}.`,
        card,
      };
    }

    const start = read(args.date, startOfDay(now));
    if (!start) {
      return fail(`could not read the date "${args.date}"; use YYYY-MM-DD`);
    }

    if (args.action === 'add') {
      if (typeof args.amount !== 'number') {
        return fail('"amount" is needed for add');
      }
      const unit = (args.unit as 'days') ?? 'days';
      const result = addToDate(start, args.amount, unit);
      const label = `${args.amount >= 0 ? '+' : '−'}${Math.abs(args.amount)} ${unit}`;
      const card: DateTimeCard = {
        type: 'datetime',
        iso: isoDate(result),
        dateText: longDate(result),
        label,
        daysFromToday: daysBetween(now, result),
      };
      return {
        text: `${isoDate(start)} ${label} = ${longDate(result)} (${isoDate(result)}).`,
        card,
      };
    }

    if (args.action === 'difference') {
      const end = read(args.other_date);
      if (!end) {
        return fail('"other_date" is needed for difference; use YYYY-MM-DD');
      }
      const days = daysBetween(start, end);
      const weeks = Math.floor(Math.abs(days) / 7);
      const card: DateTimeCard = {
        type: 'datetime',
        iso: isoDate(end),
        dateText: longDate(end),
        label: `${Math.abs(days)} days`,
        daysFromToday: daysBetween(now, end),
      };
      return {
        text: `From ${isoDate(start)} to ${isoDate(end)}: ${Math.abs(days)} days${
          weeks >= 2 ? ` (${weeks} weeks and ${Math.abs(days) % 7} days)` : ''
        }${days < 0 ? '; the second date is earlier' : ''}.`,
        card,
      };
    }

    const card: DateTimeCard = {
      type: 'datetime',
      iso: isoDate(start),
      dateText: longDate(start),
      daysFromToday: daysBetween(now, start),
    };
    return {text: `${isoDate(start)} is a ${WEEKDAYS[start.getDay()]}.`, card};
  },
};
