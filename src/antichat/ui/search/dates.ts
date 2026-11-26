const DAY_MS = 24 * 60 * 60 * 1000;

function startOfDay(time: number): number {
  const date = new Date(time);
  date.setHours(0, 0, 0, 0);
  return date.getTime();
}

export interface DateLabels {
  today: string;
  yesterday: string;
}

/**
 * A short date for the end of a row: "Today", "Yesterday", "3 Nov", and
 * "3 Nov 2025" for another year. Day and month in the phone's own order.
 */
export function shortDate(
  time: number,
  now: number,
  labels: DateLabels,
): string {
  const days = Math.round((startOfDay(now) - startOfDay(time)) / DAY_MS);
  if (days <= 0) {
    return labels.today;
  }
  if (days === 1) {
    return labels.yesterday;
  }
  const date = new Date(time);
  const sameYear = date.getFullYear() === new Date(now).getFullYear();
  try {
    return date.toLocaleDateString(undefined, {
      day: 'numeric',
      month: 'short',
      ...(sameYear ? null : {year: 'numeric'}),
    });
  } catch {
    return date.toISOString().slice(0, 10);
  }
}
