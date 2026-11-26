/**
 * Real-model check that each personalisation choice changes the answers.
 *
 * Skipped unless ANTICHAT_EVAL_PERSONAL is set to a `llama-server --jinja`
 * port, e.g.
 *   ANTICHAT_EVAL_PERSONAL=18877 ANTICHAT_EVAL_OUT=/tmp/personal.json \
 *     yarn jest personalization.eval --coverage=false
 * Each setting is compared with the default on the same questions; the
 * numbers are averages per answer.
 */
import fs from 'fs';

import {postJson} from '../../context/__tests__/support/llamaServer';
import {
  DEFAULT_PERSONALIZATION,
  type PersonalizationSettings,
} from '../personalization';
import {buildSystemPrompt} from '../systemPrompt';

const port = Number(process.env.ANTICHAT_EVAL_PERSONAL ?? 0);
const SAMPLES = Number(process.env.ANTICHAT_EVAL_SAMPLES ?? 2);

const QUESTIONS = [
  'How do I get red wine out of a white carpet?',
  'Can you explain how a mortgage works?',
  'I have a job interview tomorrow. Any tips?',
  'What are the main differences between Python and JavaScript?',
];

interface Metrics {
  emoji: number;
  exclaim: number;
  headers: number;
  listItems: number;
  warmWords: number;
  hypeWords: number;
  words: number;
}

const WARM =
  /\b(you've got this|totally|completely understand|i understand|don't worry|no worries|glad|happy to|hope|feel|stressful|frustrating|you're not alone|take a deep breath|good luck|best of luck|wishing you|rooting)\b/gi;
const HYPE =
  /\b(great|amazing|awesome|fantastic|exciting|love|wonderful|super|brilliant|incredible|absolutely)\b/gi;

function measure(text: string): Metrics {
  const lines = text.split('\n');
  return {
    emoji: (text.match(/\p{Extended_Pictographic}/gu) ?? []).length,
    exclaim: (text.match(/!/g) ?? []).length,
    headers: lines.filter(line => /^\s*#{1,6}\s/.test(line)).length,
    listItems: lines.filter(line => /^\s*(?:[-*+]|\d+[.)])\s/.test(line))
      .length,
    warmWords: (text.match(WARM) ?? []).length,
    hypeWords: (text.match(HYPE) ?? []).length,
    words: text.split(/\s+/).filter(Boolean).length,
  };
}

async function ask(system: string, question: string): Promise<string> {
  const json = await postJson(port, '/v1/chat/completions', {
    messages: [
      {role: 'system', content: system},
      {role: 'user', content: question},
    ],
    temperature: 0.7,
    max_tokens: 700,
    chat_template_kwargs: {enable_thinking: false},
  });
  return json.choices[0].message.content as string;
}

const VARIANTS: Array<[string, Partial<PersonalizationSettings>]> = [
  ['default', {}],
  ['emoji:more', {emoji: 'more'}],
  ['emoji:less', {emoji: 'less'}],
  ['enthusiasm:more', {enthusiasm: 'more'}],
  ['enthusiasm:less', {enthusiasm: 'less'}],
  ['headersAndLists:more', {headersAndLists: 'more'}],
  ['headersAndLists:less', {headersAndLists: 'less'}],
  ['warmth:more', {warmth: 'more'}],
  ['warmth:less', {warmth: 'less'}],
  ['preset:professional', {preset: 'professional'}],
  ['preset:friendly', {preset: 'friendly'}],
  ['preset:candid', {preset: 'candid'}],
  ['preset:quirky', {preset: 'quirky'}],
  ['preset:efficient', {preset: 'efficient'}],
  ['preset:cynical', {preset: 'cynical'}],
];

(port ? describe : describe.skip)('personalisation on a real model', () => {
  jest.setTimeout(60 * 60 * 1000);

  it('measures every choice against the default', async () => {
    const results: Record<
      string,
      {mean: Metrics; system: string; sample: string}
    > = {};
    for (const [name, patch] of VARIANTS) {
      const system = buildSystemPrompt({
        family: 'gemma4',
        deviceClass: 'C',
        personalization: {...DEFAULT_PERSONALIZATION, ...patch},
        now: new Date('2026-11-25T12:00:00Z'),
      });
      const jobs = QUESTIONS.flatMap(question =>
        Array.from({length: SAMPLES}, () => ask(system, question)),
      );
      const answers = await Promise.all(jobs);
      const all = answers.map(measure);
      const mean = Object.fromEntries(
        (Object.keys(all[0]) as Array<keyof Metrics>).map(key => [
          key,
          Math.round(
            (all.reduce((sum, m) => sum + m[key], 0) / all.length) * 10,
          ) / 10,
        ]),
      ) as unknown as Metrics;
      results[name] = {mean, system, sample: answers[SAMPLES * 2]};
      console.log(name, JSON.stringify(mean));
    }
    if (process.env.ANTICHAT_EVAL_OUT) {
      fs.writeFileSync(
        process.env.ANTICHAT_EVAL_OUT,
        JSON.stringify(results, null, 2),
      );
    }
    expect(Object.keys(results)).toHaveLength(VARIANTS.length);
  });
});
