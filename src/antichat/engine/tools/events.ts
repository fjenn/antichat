/**
 * Typed tool events for the UI (tool chips, the search status row, cards).
 * One stream per turn; the UI half subscribes and never reads harness state.
 */
import type {RichCard} from './cards';
import type {ToolImage, ToolSource} from './types';

interface Base {
  turnId: string;
  callId: string;
  name: string;
  at: number;
}

export type ToolEvent =
  | (Base & {
      type: 'started';
      args: Record<string, unknown>;
      /** Short present-tense label for the status row ("Searching the web"). */
      label: string;
      /** The harness made this call itself (forced search), not the model. */
      synthetic?: boolean;
    })
  | (Base & {type: 'progress'; note: string; fraction?: number})
  | (Base & {
      type: 'result';
      durationMs: number;
      /** What the model was shown. */
      text: string;
      card?: RichCard;
      sources?: ToolSource[];
      images?: ToolImage[];
    })
  | (Base & {
      type: 'error';
      durationMs: number;
      /** invalid_arguments | unknown_tool | timeout | failed | skipped | offline */
      code:
        | 'invalid_arguments'
        | 'unknown_tool'
        | 'timeout'
        | 'failed'
        | 'skipped'
        | 'offline'
        | 'cancelled';
      message: string;
      /** A repair prompt went back to the model; another attempt may follow. */
      willRetry: boolean;
    });

export type ToolEventListener = (event: ToolEvent) => void;

const listeners = new Set<ToolEventListener>();

/** Subscribe to every tool event of the app. Returns the unsubscribe. */
export function subscribeToolEvents(listener: ToolEventListener): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function emitToolEvent(event: ToolEvent): void {
  listeners.forEach(listener => {
    try {
      listener(event);
    } catch (error) {
      console.warn('[antichat] tool event listener failed', error);
    }
  });
}

const LABELS: Record<string, string> = {
  web_search: 'Searching the web',
  read_url: 'Reading the page',
  search_tools: 'Looking for a tool',
  calculator: 'Calculating',
  convert_units: 'Converting',
  date_time: 'Checking the date',
  set_timer: 'Setting a timer',
  weather: 'Checking the weather',
  image_search: 'Looking for images',
};

export function toolLabel(name: string): string {
  return LABELS[name] ?? `Using ${name.replace(/_/g, ' ')}`;
}
