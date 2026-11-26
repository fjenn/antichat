/**
 * The turn the app is in, as the tool layer knows it. The selection provider
 * opens a turn when it prepares a request; the talent adapter reads it when
 * upstream's agent runner dispatches a call, so guards (one repair, duplicate
 * calls, budgets) hold for the whole turn although the calls arrive one by
 * one through someone else's loop.
 */
import type {TurnGuards} from './execute';
import type {AntichatTool, ToolContext} from './types';

export interface ActiveTurn {
  turnId: string;
  chatId?: string;
  guards: TurnGuards;
  offered: AntichatTool[];
  context: ToolContext;
  resultChars?: number;
}

let active: ActiveTurn | null = null;

export function beginTurn(turn: ActiveTurn): void {
  active = turn;
}

export function currentTurn(): ActiveTurn | null {
  return active;
}

export function endTurn(turnId?: string): void {
  if (!turnId || active?.turnId === turnId) {
    active = null;
  }
}
