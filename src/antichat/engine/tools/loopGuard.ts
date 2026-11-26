/**
 * Loop and runaway guards for one turn (H13). Bounds and notices follow the
 * AntiChat Mac `ToolLoopPolicy` (itself from Osaurus, MIT).
 */
import type {DeviceClass} from '../prompt/types';

export interface LoopPolicy {
  /** Model steps per turn that may call tools. */
  maxSteps: number;
  /** Tool calls per turn, across steps. */
  maxCalls: number;
  /** Calls run from a single model step. */
  maxCallsPerStep: number;
  /** Same tool with near-identical arguments this many times → stop. */
  maxSimilarCalls: number;
}

/** Steps by device class (A = 4 GB … D = 12 GB+); Mac T0 = 2–3, T1+ = 6. */
export const LOOP_POLICY: Record<DeviceClass, LoopPolicy> = {
  A: {maxSteps: 3, maxCalls: 4, maxCallsPerStep: 2, maxSimilarCalls: 2},
  B: {maxSteps: 4, maxCalls: 6, maxCallsPerStep: 3, maxSimilarCalls: 2},
  C: {maxSteps: 5, maxCalls: 8, maxCallsPerStep: 4, maxSimilarCalls: 3},
  D: {maxSteps: 6, maxCalls: 10, maxCallsPerStep: 4, maxSimilarCalls: 3},
};

export const DUPLICATE_NOTICE =
  '[System Notice] Duplicate call skipped: you already made this exact call this turn. Use the result you already have and answer.';

export const BUDGET_NOTICE =
  '[System Notice] Tool budget used up. Answer now using only the information gathered above; if it is not enough, say what is missing.';

export const cutOffNotice = (name: string): string =>
  `[System Notice] Your ${name} call was cut off: it reached the output limit before its arguments were complete, so it was not run. Call ${name} again with shorter arguments: only the keys that are needed, no repeated or nested copies of the same keys.`;

export type GuardVerdict =
  | {action: 'run'}
  | {
      action: 'skip';
      reason: 'duplicate' | 'similar' | 'budget';
      notice: string;
    };

const canonical = (value: unknown): string => {
  if (Array.isArray(value)) {
    return `[${value.map(canonical).join(',')}]`;
  }
  if (value && typeof value === 'object') {
    return `{${Object.keys(value as object)
      .sort()
      .map(
        key => `${key}:${canonical((value as Record<string, unknown>)[key])}`,
      )
      .join(',')}}`;
  }
  if (typeof value === 'string') {
    return value
      .toLowerCase()
      .replace(/[^\p{L}\p{N}]+/gu, ' ')
      .trim();
  }
  return String(value);
};

/** Key under which two calls count as the same call. */
export function callKey(name: string, args: unknown): string {
  return `${name}(${canonical(args)})`;
}

const words = (text: string): Set<string> =>
  new Set(text.split(/[^\p{L}\p{N}]+/u).filter(word => word.length > 1));

/** Jaccard overlap of the words of two canonical argument strings. */
function similarity(a: string, b: string): number {
  const left = words(a);
  const right = words(b);
  if (left.size === 0 || right.size === 0) {
    return a === b ? 1 : 0;
  }
  let shared = 0;
  left.forEach(word => {
    if (right.has(word)) {
      shared++;
    }
  });
  return shared / (left.size + right.size - shared);
}

export class LoopGuard {
  private steps = 0;
  private calls = 0;
  private readonly seen = new Map<string, number>();
  private readonly byTool = new Map<string, string[]>();

  constructor(readonly policy: LoopPolicy) {}

  get stepsUsed(): number {
    return this.steps;
  }

  get callsUsed(): number {
    return this.calls;
  }

  /** Call before each model step; false once the step budget is spent. */
  beginStep(): boolean {
    if (this.steps >= this.policy.maxSteps) {
      return false;
    }
    this.steps += 1;
    return true;
  }

  /** True when no further tool-calling step is allowed after this one. */
  get lastStep(): boolean {
    return this.steps >= this.policy.maxSteps;
  }

  /** Decide whether a validated call may run. Records it when it may. */
  admit(name: string, args: unknown): GuardVerdict {
    const key = callKey(name, args);
    if (this.seen.has(key)) {
      this.seen.set(key, (this.seen.get(key) ?? 1) + 1);
      return {action: 'skip', reason: 'duplicate', notice: DUPLICATE_NOTICE};
    }
    if (this.calls >= this.policy.maxCalls) {
      return {action: 'skip', reason: 'budget', notice: BUDGET_NOTICE};
    }
    const previous = this.byTool.get(name) ?? [];
    const argsKey = canonical(args);
    const near = previous.filter(other => similarity(other, argsKey) >= 0.8);
    if (near.length >= this.policy.maxSimilarCalls) {
      return {
        action: 'skip',
        reason: 'similar',
        notice: `[System Notice] Call skipped: you already called ${name} ${near.length} times with almost the same arguments. Use the results you have and answer.`,
      };
    }
    this.seen.set(key, 1);
    this.byTool.set(name, [...previous, argsKey]);
    this.calls += 1;
    return {action: 'run'};
  }
}

/**
 * Runaway text: the same line or phrase repeated until the output limit.
 * Used on a truncated generation to tell "long answer" from "stuck".
 */
export function looksRunaway(text: string): boolean {
  const tail = text.slice(-1200);
  if (tail.length < 200) {
    return false;
  }
  const lines = tail
    .split('\n')
    .map(line => line.trim())
    .filter(line => line.length > 3);
  if (lines.length >= 6) {
    const counts = new Map<string, number>();
    for (const line of lines) {
      counts.set(line, (counts.get(line) ?? 0) + 1);
    }
    if (Math.max(...counts.values()) >= Math.max(4, lines.length * 0.5)) {
      return true;
    }
  }
  // A short unit (≤ 40 chars) repeated back to back at least 8 times.
  return /(.{2,40}?)\1{7,}$/s.test(tail);
}
