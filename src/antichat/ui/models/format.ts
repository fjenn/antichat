/**
 * Sizes and durations the way a person reads them: "5.2 GB", "about 4 min".
 * Decimal units, as phone storage settings and download pages use.
 */
const KB = 1000;
const MB = KB * 1000;
const GB = MB * 1000;

export const BYTES = {KB, MB, GB} as const;

/** "5.2 GB", "840 MB", "12 KB". One decimal under 10 GB, none above. */
export function formatBytes(bytes: number): string {
  const value = Number.isFinite(bytes) ? Math.max(0, bytes) : 0;
  if (value >= GB) {
    const gb = value / GB;
    return `${gb >= 10 ? Math.round(gb) : trim(gb)} GB`;
  }
  if (value >= MB) {
    return `${Math.round(value / MB)} MB`;
  }
  if (value >= KB) {
    return `${Math.round(value / KB)} KB`;
  }
  return `${Math.round(value)} B`;
}

/** "1.3 of 5.2 GB": the unit is said once when both sides share it. */
export function formatProgressBytes(received: number, total: number): string {
  const whole = formatBytes(total);
  const part = formatBytes(received);
  const unit = whole.split(' ')[1];
  if (part.endsWith(` ${unit}`)) {
    return `${part.split(' ')[0]} of ${whole}`;
  }
  return `${part} of ${whole}`;
}

const trim = (value: number): string => {
  const fixed = value.toFixed(1);
  return fixed.endsWith('.0') ? fixed.slice(0, -2) : fixed;
};

export type DurationParts =
  | {unit: 'moment'}
  | {unit: 'seconds'; value: number}
  | {unit: 'minutes'; value: number}
  | {unit: 'hours'; value: number};

/**
 * A calm estimate: seconds are rounded to tens so the line does not flicker,
 * and nothing under ten seconds is counted down.
 */
export function durationParts(
  seconds: number | undefined,
): DurationParts | null {
  if (seconds === undefined || !Number.isFinite(seconds) || seconds < 0) {
    return null;
  }
  if (seconds < 10) {
    return {unit: 'moment'};
  }
  if (seconds < 55) {
    return {unit: 'seconds', value: Math.round(seconds / 10) * 10};
  }
  if (seconds < 55 * 60) {
    return {unit: 'minutes', value: Math.max(1, Math.round(seconds / 60))};
  }
  return {unit: 'hours', value: Math.max(1, Math.round(seconds / 3600))};
}

/** Whole percent, never 100 before the work is done. */
export function formatPercent(fraction: number): string {
  const clamped = Math.min(
    1,
    Math.max(0, Number.isFinite(fraction) ? fraction : 0),
  );
  const percent = clamped >= 1 ? 100 : Math.min(99, Math.round(clamped * 100));
  return `${percent}%`;
}
