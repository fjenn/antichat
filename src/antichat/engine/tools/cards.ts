/**
 * Data shapes of the rich answer cards. The engine only produces the data;
 * `ui/cards/` (M8 UI half) draws them. Every card is plain JSON so it can be
 * stored with the message and redrawn later.
 */

export interface CalculatorCard {
  type: 'calculator';
  expression: string;
  /** Formatted for display, e.g. "391" or "0.3333". */
  result: string;
  value: number;
}

export interface ConversionCard {
  type: 'conversion';
  quantity: string;
  from: {value: number; unit: string; label: string};
  to: {value: number; unit: string; label: string};
  /** Display text, e.g. "5 mi = 8.047 km". */
  text: string;
}

export interface DateTimeCard {
  type: 'datetime';
  /** ISO 8601 local date-time of the answer. */
  iso: string;
  timeZone?: string;
  /** e.g. "Tuesday, 24 November 2026" */
  dateText: string;
  /** e.g. "14:05" */
  timeText?: string;
  /** For date arithmetic: what was asked, e.g. "in 10 days". */
  label?: string;
  /** Whole days between today and `iso`, when a difference was asked. */
  daysFromToday?: number;
}

export interface TimerCard {
  type: 'timer';
  kind: 'timer' | 'alarm';
  label?: string;
  /** Countdown length; set for timers. */
  durationSeconds?: number;
  /** ISO 8601 moment the timer or alarm fires. */
  firesAt: string;
  createdAt: string;
}

export interface WeatherDay {
  date: string;
  minC: number;
  maxC: number;
  condition: string;
  /** Stable icon key: clear, partly, cloudy, fog, drizzle, rain, snow, storm. */
  icon: string;
  precipitationChance?: number;
}

export interface WeatherCard {
  type: 'weather';
  place: string;
  country?: string;
  latitude: number;
  longitude: number;
  /** Temperatures are stored in Celsius; `unit` is how to show them. */
  unit: 'C' | 'F';
  current: {
    temperatureC: number;
    feelsLikeC?: number;
    condition: string;
    icon: string;
    windKmh?: number;
    humidity?: number;
    observedAt: string;
  };
  days: WeatherDay[];
  source: {name: string; url: string};
}

export interface SourcesCard {
  type: 'sources';
  query: string;
  count: number;
}

export interface HelplineCard {
  type: 'helpline';
  countryCode?: string;
  name: string;
  phone?: string;
  url?: string;
}

export interface ChartCard {
  type: 'chart';
  kind: 'bar' | 'line' | 'pie' | 'scatter';
  title?: string;
  labels: string[];
  series: Array<{name: string; values: number[]}>;
  unit?: string;
}

export interface WritingCard {
  type: 'writing';
  kind: 'email' | 'document' | 'message';
  title?: string;
  body: string;
}

export interface QuizCard {
  type: 'quiz';
  title?: string;
  items: Array<{
    question: string;
    choices?: string[];
    answer: string;
    explanation?: string;
  }>;
}

/** A connector the model needs is not connected: the chat shows the button. */
export interface ConnectAppCard {
  type: 'connect_app';
  /** Toolkit slug; null = an app the directory does not have. */
  slug: string | null;
  name: string;
  direct?: boolean;
}

export type RichCard =
  | ConnectAppCard
  | CalculatorCard
  | ConversionCard
  | DateTimeCard
  | TimerCard
  | WeatherCard
  | SourcesCard
  | HelplineCard
  | ChartCard
  | WritingCard
  | QuizCard;

export type RichCardType = RichCard['type'];
