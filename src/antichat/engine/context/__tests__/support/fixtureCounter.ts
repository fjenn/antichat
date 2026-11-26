/**
 * Real-tokeniser fixtures for Jest.
 *
 * Counts in the fixture file were produced by the models' own tokenisers and
 * chat templates through `llama-server` (see `recordFixtures.test.ts`). In
 * replay the counter only looks counts up; a text that was never recorded
 * throws, so a test cannot silently fall back to an estimate.
 */
import crypto from 'crypto';
import fs from 'fs';

import type {ChatMessage, ToolDefinition} from '../../../prompt/types';
import type {TokenCounter} from '../../tokenCounter';

export type FixtureTable = Record<string, number>;

const key = (kind: 't' | 'p', value: string): string =>
  kind +
  crypto.createHash('sha1').update(value, 'utf8').digest('base64').slice(0, 10);

const promptKey = (
  messages: readonly ChatMessage[],
  tools?: readonly ToolDefinition[],
): string => key('p', JSON.stringify([messages, tools ?? []]));

export function loadFixture(path: string): FixtureTable {
  return fs.existsSync(path) ? JSON.parse(fs.readFileSync(path, 'utf8')) : {};
}

export function saveFixture(path: string, table: FixtureTable): void {
  const sorted = Object.fromEntries(
    Object.entries(table).sort(([a], [b]) => (a < b ? -1 : 1)),
  );
  fs.writeFileSync(path, JSON.stringify(sorted));
}

/** Counter that answers from the fixture and throws on anything unknown. */
export function createReplayCounter(table: FixtureTable): TokenCounter {
  const lookup = (id: string, what: string): number => {
    const count = table[id];
    if (count === undefined) {
      throw new Error(
        `No recorded token count for ${what}. Re-record the fixtures (see context/__tests__/recordFixtures.test.ts).`,
      );
    }
    return count;
  };
  return {
    exact: true,
    countText: async text =>
      text ? lookup(key('t', text), `text "${text.slice(0, 40)}…"`) : 0,
    countPrompt: async (messages, tools) =>
      lookup(
        promptKey(messages, tools),
        `prompt of ${messages.length} messages`,
      ),
  };
}

/** Counter that asks the real tokeniser and writes every answer down. */
export function createRecordingCounter(
  real: TokenCounter,
  table: FixtureTable,
): TokenCounter {
  return {
    exact: true,
    countText: async text => {
      if (!text) {
        return 0;
      }
      const id = key('t', text);
      if (table[id] === undefined) {
        table[id] = await real.countText(text);
      }
      return table[id];
    },
    countPrompt: async (messages, tools) => {
      const id = promptKey(messages, tools);
      if (table[id] === undefined) {
        table[id] = await real.countPrompt(messages, tools);
      }
      return table[id];
    },
  };
}
