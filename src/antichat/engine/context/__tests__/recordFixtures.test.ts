/**
 * Records the real-tokeniser fixtures used by `longChat.test.ts`.
 *
 * Skipped unless ANTICHAT_RECORD is set:
 *   ANTICHAT_RECORD="gemma4:18171,lfm3:18172,qwen35:18173" \
 *     yarn jest recordFixtures --coverage=false
 * with one `llama-server --jinja` per port, each loaded with that family's
 * model. Counts come from the model's tokeniser and chat template.
 */
import type {ModelFamily} from '../../prompt/modelFamily';
import {
  createRecordingCounter,
  loadFixture,
  saveFixture,
} from './support/fixtureCounter';
import {createServerCounter} from './support/llamaServer';
import {WINDOWS, fixturePath, runScriptedChat} from './support/scriptedChat';

const targets = (process.env.ANTICHAT_RECORD ?? '')
  .split(',')
  .filter(Boolean)
  .map(entry => {
    const [family, port] = entry.split(':');
    return {family: family as ModelFamily, port: Number(port)};
  });

if (targets.length === 0) {
  it('fixture recording is skipped without ANTICHAT_RECORD', () => {
    expect(targets).toHaveLength(0);
  });
}

const suite = targets.length
  ? describe.each(targets)
  : describe.skip.each([{family: 'generic' as ModelFamily, port: 0}]);

suite('record $family', ({family, port}) => {
  it('runs the scripted chat at every window against the real tokeniser', async () => {
    const table = process.env.ANTICHAT_RECORD_FRESH
      ? {}
      : loadFixture(fixturePath(family));
    const counter = createRecordingCounter(createServerCounter(port), table);
    for (const nCtx of WINDOWS) {
      const result = await runScriptedChat({family, nCtx, counter});
      expect(result.maxPromptTokens).toBeLessThanOrEqual(result.promptLimit);
    }
    saveFixture(fixturePath(family), table);
    expect(Object.keys(table).length).toBeGreaterThan(400);
  }, 3600000);
});
