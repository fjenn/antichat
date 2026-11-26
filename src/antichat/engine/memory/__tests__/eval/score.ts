/**
 * Scoring for the extraction head-to-head: compares the memories an
 * approach left behind with a case's labels. Pure; unit-tested.
 */
import {fold} from '../../text';
import type {EvalCase, Matcher} from './extractionSet';

export interface FinalMemory {
  text: string;
  /** Index of the seed this memory is, when it is an untouched seed. */
  unchangedSeed: boolean;
}

export interface CaseScore {
  id: string;
  category: string;
  expected: number;
  found: number;
  /** Memories the approach wrote or rewrote. */
  written: number;
  correct: number;
  allowed: number;
  redundant: number;
  /** Written memories that match a `forbid` label. */
  forbidden: number;
  /** Seeds that should have been corrected and were left as they were. */
  stale: number;
  spurious: number;
  /** `kept` seeds that are gone. */
  lost: number;
  missed: string[];
  wrong: string[];
}

export function matches(matcher: Matcher, text: string): boolean {
  const folded = fold(text);
  return (
    matcher.all.every(pattern => new RegExp(pattern, 'i').test(folded)) &&
    !(matcher.none ?? []).some(pattern => new RegExp(pattern, 'i').test(folded))
  );
}

export function scoreCase(testCase: EvalCase, final: FinalMemory[]): CaseScore {
  const expect = testCase.expect;
  const claimed = new Set<number>();
  const score: CaseScore = {
    id: testCase.id,
    category: testCase.category,
    expected: expect.length,
    found: 0,
    written: 0,
    correct: 0,
    allowed: 0,
    redundant: 0,
    forbidden: 0,
    stale: 0,
    spurious: 0,
    lost: 0,
    missed: [],
    wrong: [],
  };
  // Most specific first: "User's name is Priya" claims the name before
  // "Priya is a nurse" (which matches both labels) claims the job.
  const hitCount = (memory: FinalMemory) =>
    expect.filter(matcher => matches(matcher, memory.text)).length;
  const ordered = [...final].sort((a, b) => hitCount(a) - hitCount(b));
  for (const memory of ordered) {
    const forbidden = (testCase.forbid ?? []).find(f =>
      matches(f, memory.text),
    );
    if (memory.unchangedSeed) {
      if (forbidden) {
        score.stale++;
        score.wrong.push(`stale (${forbidden.label}): ${memory.text}`);
      }
      continue;
    }
    score.written++;
    if (forbidden) {
      score.forbidden++;
      score.wrong.push(`forbidden (${forbidden.label}): ${memory.text}`);
      continue;
    }
    const hits = expect
      .map((matcher, index) => (matches(matcher, memory.text) ? index : -1))
      .filter(index => index >= 0);
    if (hits.length > 0) {
      const fresh = hits.filter(index => !claimed.has(index));
      if (fresh.length > 0) {
        fresh.forEach(index => claimed.add(index));
        score.correct++;
      } else {
        score.redundant++;
        score.wrong.push(`redundant: ${memory.text}`);
      }
      continue;
    }
    const keptHit = (testCase.kept ?? []).some(k => matches(k, memory.text));
    if (keptHit) {
      // A rewritten seed is fine; a second copy of it is clutter.
      const copies = final.filter(other =>
        (testCase.kept ?? []).some(
          k => matches(k, other.text) && matches(k, memory.text),
        ),
      ).length;
      if (copies > 1) {
        score.redundant++;
        score.wrong.push(`redundant: ${memory.text}`);
      } else {
        score.allowed++;
      }
      continue;
    }
    if ((testCase.allow ?? []).some(a => matches(a, memory.text))) {
      score.allowed++;
      continue;
    }
    score.spurious++;
    score.wrong.push(`spurious: ${memory.text}`);
  }
  score.found = claimed.size;
  expect.forEach((matcher, index) => {
    if (!claimed.has(index)) {
      score.missed.push(matcher.label);
    }
  });
  for (const kept of testCase.kept ?? []) {
    if (!final.some(memory => matches(kept, memory.text))) {
      score.lost++;
      score.wrong.push(`lost: ${kept.label}`);
    }
  }
  return score;
}

export interface Totals {
  cases: number;
  expected: number;
  found: number;
  written: number;
  correct: number;
  allowed: number;
  redundant: number;
  forbidden: number;
  stale: number;
  spurious: number;
  lost: number;
  /** correct / (correct + redundant + forbidden + stale + spurious). */
  precision: number;
  /** found / expected. */
  recall: number;
  f1: number;
  /** Cases with nothing wrong and nothing missed. */
  cleanCases: number;
}

export function totals(scores: CaseScore[]): Totals {
  const sum = (key: keyof CaseScore) =>
    scores.reduce((acc, score) => acc + (score[key] as number), 0);
  const correct = sum('correct');
  const wrong =
    sum('redundant') + sum('forbidden') + sum('stale') + sum('spurious');
  const expected = sum('expected');
  const found = sum('found');
  const precision = correct + wrong === 0 ? 1 : correct / (correct + wrong);
  const recall = expected === 0 ? 1 : found / expected;
  return {
    cases: scores.length,
    expected,
    found,
    written: sum('written'),
    correct,
    allowed: sum('allowed'),
    redundant: sum('redundant'),
    forbidden: sum('forbidden'),
    stale: sum('stale'),
    spurious: sum('spurious'),
    lost: sum('lost'),
    precision,
    recall,
    f1:
      precision + recall === 0
        ? 0
        : (2 * precision * recall) / (precision + recall),
    cleanCases: scores.filter(
      score => score.wrong.length === 0 && score.missed.length === 0,
    ).length,
  };
}
