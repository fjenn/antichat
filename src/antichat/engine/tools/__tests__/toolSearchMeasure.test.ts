/**
 * `search_tools` retrieval measured on the Mac's tool-select-200 set: 40
 * tools (built-ins, MCP servers, Composio meta tools), 144 prompts that need
 * one of them in six languages. The index sees only names and descriptions
 * (no hand-written keywords), and the raw user prompt stands in for the
 * query a model would write. The bars are regression floors under the
 * measured values in docs/antichat/m8-eval.md.
 */
import set from '../__fixtures__/tool-select-200.json';
import {ToolCatalog} from '../catalog';
import type {AntichatTool} from '../types';

interface Row {
  id: string;
  lang: string;
  prompt: string;
  gold: string;
  also: string[];
}

const data = set as {
  tools: Array<{name: string; description: string}>;
  rows: Row[];
};

function measure(limit: number) {
  const catalog = new ToolCatalog();
  for (const tool of data.tools) {
    catalog.register({
      name: tool.name,
      description: tool.description,
      parameters: {type: 'object', properties: {}},
      kind: 'local',
      tier: 'deferred',
      execute: async () => ({text: ''}),
    } as AntichatTool);
  }
  const needed = data.rows.filter(row => row.gold !== 'none');
  const byLanguage: Record<string, {hit: number; total: number}> = {};
  let hit = 0;
  for (const row of needed) {
    const found = catalog
      .search(row.prompt, {limit})
      .map(item => item.tool.name);
    const ok = [row.gold, ...row.also].some(name => found.includes(name));
    const entry = (byLanguage[row.lang] ??= {hit: 0, total: 0});
    entry.total += 1;
    if (ok) {
      hit += 1;
      entry.hit += 1;
    }
  }
  return {recall: hit / needed.length, n: needed.length, byLanguage};
}

describe('search_tools retrieval on tool-select-200', () => {
  it('finds the right tool among 40 from the prompt alone', () => {
    const top3 = measure(3);
    const top5 = measure(5);
    if (process.env.ANTICHAT_PRINT) {
      console.log(JSON.stringify({top3, top5}));
    }
    expect(
      top3.byLanguage.en.hit / top3.byLanguage.en.total,
    ).toBeGreaterThanOrEqual(0.7);
    expect(top5.recall).toBeGreaterThanOrEqual(top3.recall);
  });
});
