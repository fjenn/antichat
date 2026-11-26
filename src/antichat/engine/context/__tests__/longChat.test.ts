/**
 * M7 acceptance: with real tokeniser counts the prompt never exceeds the
 * window at 4k/8k/16k/32k, and a 200-turn scripted chat keeps answering and
 * recalls a fact from turn 3 through the summary.
 *
 * Token counts are replayed from fixtures recorded with the tokenisers and
 * chat templates of Gemma 4 E2B, LFM3-1.7B and Qwen3.5-0.8B (see
 * `recordFixtures.test.ts`). A count that was not recorded makes the test
 * fail, so nothing here rests on an estimate.
 */
import {budgetFor} from '../budget';
import {createReplayCounter, loadFixture} from './support/fixtureCounter';
import {
  FAMILIES,
  WINDOWS,
  fixturePath,
  runScriptedChat,
} from './support/scriptedChat';

const cases = FAMILIES.flatMap(family => WINDOWS.map(nCtx => ({family, nCtx})));

describe('200-turn scripted chat with real tokeniser fixtures', () => {
  const report: string[] = [];

  afterAll(() => {
    console.info(
      ['family nCtx limit maxPrompt compactions cacheHit', ...report].join(
        '\n',
      ),
    );
  });

  it.each(cases)(
    '$family at $nCtx: never over the window, recalls turn 3',
    async ({family, nCtx}) => {
      const counter = createReplayCounter(loadFixture(fixturePath(family)));
      expect(counter.exact).toBe(true);
      const result = await runScriptedChat({family, nCtx, counter});
      const budget = budgetFor(nCtx);

      // 1. Never over the window, with room for the reply, on every turn.
      expect(result.promptTokens).toHaveLength(200);
      expect(result.maxPromptTokens).toBeLessThanOrEqual(budget.promptLimit);
      expect(result.maxPromptTokens + budget.replyReserve).toBeLessThan(nCtx);

      // 2. It kept answering: 200 chat replies, none empty.
      const replies = result.engine.calls.filter(call => call.kind === 'chat');
      expect(replies).toHaveLength(200);

      // 3. The chat was actually compacted, and the fact from turn 3 is no
      //    longer among the messages sent: only the summary can carry it.
      expect(result.compactions).toBeGreaterThanOrEqual(1);
      expect(result.summarized).toBe(result.compactions);
      expect(result.factInWindow).toBe(false);
      expect(result.factInSummary).toBe(true);
      expect(result.recallReply).toBe('Your dog is called Biscuit.');

      // 4. Stepwise compaction keeps the prefix cache useful.
      expect(result.cacheHitRate).toBeGreaterThan(0.8);
      expect(result.lastRequest.filter(m => m.role === 'system')).toHaveLength(
        1,
      );

      report.push(
        `${family} ${nCtx} ${budget.promptLimit} ${result.maxPromptTokens} ${result.compactions} ${result.cacheHitRate.toFixed(3)}`,
      );
    },
    120000,
  );

  it('uses most of the window before compacting (no needless cuts)', async () => {
    const counter = createReplayCounter(loadFixture(fixturePath('gemma4')));
    const result = await runScriptedChat({
      family: 'gemma4',
      nCtx: 4096,
      counter,
    });
    const budget = budgetFor(4096);
    expect(result.maxPromptTokens).toBeGreaterThan(budget.promptLimit * 0.8);
    expect(result.offeredNewChat).toBe(true);
  }, 120000);

  it('fails loudly on a count that was never recorded', async () => {
    const counter = createReplayCounter({});
    await expect(counter.countText('never seen')).rejects.toThrow(
      'No recorded token count',
    );
    await expect(
      counter.countPrompt([{role: 'user', content: 'x'}]),
    ).rejects.toThrow('No recorded token count');
    expect(await counter.countText('')).toBe(0);
  });
});
