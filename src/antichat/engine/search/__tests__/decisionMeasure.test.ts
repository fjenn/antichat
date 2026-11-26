/**
 * The rule gate measured on the Mac's fresh-vs-stable-200 set (100 prompts
 * that need current information, 100 that do not, six languages). The bars
 * are regression floors a little under the measured values recorded in
 * docs/antichat/m8-eval.md.
 */
import set from '../__fixtures__/fresh-vs-stable-200.json';
import {decideSearch} from '../decision';

interface Row {
  id: string;
  lang: string;
  prompt: string;
  label: 'fresh' | 'stable';
}

export function measureGate(rows: Row[], cutoff = '2026-01') {
  let forceFresh = 0;
  let forceStable = 0;
  let noneFresh = 0;
  let noneStable = 0;
  const missed: string[] = [];
  const wrong: string[] = [];
  const withheld: string[] = [];
  for (const row of rows) {
    const verdict = decideSearch({
      userText: row.prompt,
      knowledgeCutoff: cutoff,
    });
    if (verdict.decision === 'force') {
      if (row.label === 'fresh') {
        forceFresh++;
      } else {
        forceStable++;
        wrong.push(row.prompt);
      }
    } else if (row.label === 'fresh') {
      missed.push(`${verdict.decision}: ${row.prompt}`);
    }
    if (verdict.decision === 'none') {
      if (row.label === 'fresh') {
        noneFresh++;
        withheld.push(row.prompt);
      } else {
        noneStable++;
      }
    }
  }
  const fresh = rows.filter(row => row.label === 'fresh').length;
  const stable = rows.length - fresh;
  return {
    precision: forceFresh / Math.max(1, forceFresh + forceStable),
    recall: forceFresh / fresh,
    /** Stable prompts where tools are withheld outright. */
    stableWithheld: noneStable / stable,
    /** Fresh prompts wrongly denied the search tool: the costly error. */
    freshWithheld: noneFresh / fresh,
    missed,
    wrong,
    withheld,
  };
}

describe('search gate on fresh-vs-stable-200', () => {
  const result = measureGate((set as {rows: Row[]}).rows);

  it('forces a search only where one is needed', () => {
    if (process.env.ANTICHAT_PRINT) {
      console.log(JSON.stringify(result, null, 1));
    }
    expect(result.precision).toBeGreaterThanOrEqual(0.95);
    expect(result.recall).toBeGreaterThanOrEqual(0.75);
  });

  it('almost never withholds the search tool from a question that needs it', () => {
    expect(result.freshWithheld).toBeLessThanOrEqual(0.03);
  });
});
