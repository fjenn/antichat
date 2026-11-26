import type {CompletionResult} from '../../../../utils/completionTypes';
import {subscribeToolEvents, type ToolEvent} from '../events';
import {capResult, executeGuarded} from '../execute';
import {LOOP_POLICY, LoopGuard} from '../loopGuard';
import {RepairState} from '../repair';
import {runToolTurn, type TurnOptions} from '../runner';
import {asTalentEngine} from '../talentAdapter';
import {beginTurn, endTurn} from '../turnState';
import type {AntichatTool} from '../types';

type Scripted = Partial<CompletionResult> & {
  calls?: Array<{name: string; args: unknown}>;
};

/** An engine that plays back scripted steps and records what it was sent. */
function scriptedEngine(steps: Scripted[]) {
  const requests: any[] = [];
  let index = 0;
  return {
    requests,
    engine: {
      async completion(params: any): Promise<CompletionResult> {
        requests.push(JSON.parse(JSON.stringify(params)));
        const step = steps[Math.min(index++, steps.length - 1)];
        return {
          text: step.content ?? '',
          content: step.content ?? '',
          tool_calls: step.calls?.map((call, position) => ({
            id: `c${index}-${position}`,
            type: 'function',
            function: {
              name: call.name,
              arguments:
                typeof call.args === 'string'
                  ? call.args
                  : JSON.stringify(call.args),
            },
          })) as never,
          truncated: step.truncated,
          tokens_evaluated: 100,
          tokens_predicted: 10,
        };
      },
      async stopCompletion() {},
    },
  };
}

const now = new Date(2026, 10, 24, 10, 0);

function tools(
  overrides: Partial<Record<string, AntichatTool['execute']>> = {},
) {
  const log: Array<{name: string; args: unknown}> = [];
  const make = (
    name: string,
    parameters: object,
    extra: Partial<AntichatTool> = {},
  ): AntichatTool => ({
    name,
    description: `${name}.`,
    parameters,
    kind: 'local',
    tier: 'always',
    async execute(args, context) {
      log.push({name, args});
      return overrides[name]
        ? overrides[name]!(args, context)
        : {text: `${name} result for ${JSON.stringify(args)}`};
    },
    ...extra,
  });
  const list = [
    make(
      'web_search',
      {
        type: 'object',
        properties: {query: {type: 'string', minLength: 1}},
        required: ['query'],
        additionalProperties: false,
      },
      {example: {query: 'x'}},
    ),
    make('email_send', {
      type: 'object',
      properties: {
        to: {type: 'array', items: {type: 'string'}},
        body: {type: 'string'},
      },
      required: ['to', 'body'],
      additionalProperties: false,
    }),
  ];
  return {list, log};
}

const base = (
  engine: TurnOptions['engine'],
  list: AntichatTool[],
  user: string,
): TurnOptions => ({
  engine,
  messages: [
    {role: 'system', content: 'sys'},
    {role: 'user', content: user},
  ],
  tools: list,
  policy: LOOP_POLICY.B,
  context: {now},
  turnId: 'turn-1',
});

describe('runToolTurn', () => {
  it('runs a native call and returns the answer', async () => {
    const {list, log} = tools();
    const {engine, requests} = scriptedEngine([
      {calls: [{name: 'web_search', args: {query: 'lisbon weather'}}]},
      {content: 'It is 17 °C.'},
    ]);
    const result = await runToolTurn(base(engine, list, 'weather in lisbon?'));
    expect(result).toMatchObject({
      text: 'It is 17 °C.',
      stopReason: 'answer',
      steps: 2,
    });
    expect(log).toEqual([
      {name: 'web_search', args: {query: 'lisbon weather'}},
    ]);
    expect(requests[0].tool_choice).toBe('auto');
    expect(requests[1].messages.slice(-2).map((m: any) => m.role)).toEqual([
      'assistant',
      'tool',
    ]);
    expect(result.calls[0]).toMatchObject({
      name: 'web_search',
      status: 'ok',
      synthetic: false,
    });
  });

  it('sends one repair prompt for a malformed call, then runs the corrected one', async () => {
    const {list, log} = tools();
    const {engine, requests} = scriptedEngine([
      {calls: [{name: 'web_search', args: {}}]},
      {calls: [{name: 'web_search', args: {query: 'fixed'}}]},
      {content: 'Done.'},
    ]);
    const result = await runToolTurn(base(engine, list, 'find it'));
    expect(result.flags.repaired).toBe(1);
    expect(requests[1].messages.at(-1)).toEqual({
      role: 'tool',
      tool_call_id: 'c1-0',
      content:
        '[System Notice] The call to web_search was not run. Errors: the arguments do not match the schema: missing required argument "query"\nFix exactly these errors and call web_search again now. A minimal valid call looks like this: {"query":"x"}',
    });
    expect(log).toEqual([{name: 'web_search', args: {query: 'fixed'}}]);
    expect(result.text).toBe('Done.');
  });

  it('ends tool use after a second malformed call and answers in text', async () => {
    const {list, log} = tools();
    const {engine, requests} = scriptedEngine([
      {calls: [{name: 'web_search', args: {}}]},
      {calls: [{name: 'no_such_tool', args: {}}]},
      {content: 'I could not search, but here is what I know.'},
    ]);
    const result = await runToolTurn(base(engine, list, 'find it'));
    expect(log).toEqual([]);
    expect(result.stopReason).toBe('repair_failed');
    expect(requests[2].tool_choice).toBe('none');
    expect(requests[2].messages.at(-1).content).toContain(
      'Do not call any more tools',
    );
  });

  it('repairs broken JSON silently with jsonrepair', async () => {
    const {list, log} = tools();
    const {engine} = scriptedEngine([
      {calls: [{name: 'web_search', args: "{'query': 'tesla price',}"}]},
      {content: 'ok'},
    ]);
    const result = await runToolTurn(base(engine, list, 'price?'));
    expect(log).toEqual([{name: 'web_search', args: {query: 'tesla price'}}]);
    expect(result.flags.repaired).toBe(0);
  });

  it('skips a repeated identical call with the duplicate notice', async () => {
    const {list, log} = tools();
    const {engine, requests} = scriptedEngine([
      {calls: [{name: 'web_search', args: {query: 'a b'}}]},
      {calls: [{name: 'web_search', args: {query: 'A  B'}}]},
      {content: 'answer'},
    ]);
    const result = await runToolTurn(base(engine, list, 'q'));
    expect(log).toHaveLength(1);
    expect(requests[2].messages.at(-1).content).toContain(
      'Duplicate call skipped',
    );
    expect(result.calls.map(call => call.status)).toEqual(['ok', 'skipped']);
  });

  it('stops at the step budget with a text-only last step', async () => {
    const {list} = tools();
    let n = 0;
    const {engine, requests} = scriptedEngine([]);
    engine.completion = async (params: any) => {
      requests.push(JSON.parse(JSON.stringify(params)));
      if (params.tool_choice === 'none') {
        return {text: 'final', content: 'final'} as CompletionResult;
      }
      n += 1;
      return {
        text: '',
        content: '',
        tool_calls: [
          {
            id: `x${n}`,
            type: 'function',
            function: {
              name: 'email_send',
              arguments: JSON.stringify({
                to: [`p${n}@example.com`],
                body: `completely different text number ${n} ${'z'.repeat(n)}`,
              }),
            },
          },
        ],
      } as never;
    };
    const result = await runToolTurn({
      ...base(engine, list, 'loop'),
      policy: {
        maxSteps: 2,
        maxCalls: 9,
        maxCallsPerStep: 2,
        maxSimilarCalls: 9,
      },
    });
    expect(result).toMatchObject({
      stopReason: 'step_budget',
      text: 'final',
      steps: 3,
    });
    expect(result.calls).toHaveLength(2);
    expect(requests[2].messages.at(-1).content).toContain(
      'Tool budget used up',
    );
  });

  it('times out a slow tool and tells the model', async () => {
    const {list} = tools({
      web_search: () =>
        new Promise(resolve => setTimeout(() => resolve({text: 'late'}), 500)),
    });
    list[0].timeoutMs = 20;
    const {engine, requests} = scriptedEngine([
      {calls: [{name: 'web_search', args: {query: 'slow'}}]},
      {content: 'Search did not respond.'},
    ]);
    const events: ToolEvent[] = [];
    const result = await runToolTurn({
      ...base(engine, list, 'q'),
      onEvent: event => events.push(event),
    });
    expect(result.calls[0].status).toBe('timeout');
    expect(requests[1].messages.at(-1).content).toContain(
      'timed out after 0 s and was stopped',
    );
    expect(events.map(event => event.type)).toEqual(['started', 'error']);
    expect(events[1]).toMatchObject({code: 'timeout', willRetry: false});
  });

  it('parses a call the model printed as text', async () => {
    const {list, log} = tools();
    const {engine} = scriptedEngine([
      {
        content:
          '<tool_call>\n{"name": "web_search", "arguments": {"query": "f1 winner"}}\n</tool_call>',
      },
      {content: 'Norris won.'},
    ]);
    const result = await runToolTurn(base(engine, list, 'who won?'));
    expect(log).toEqual([{name: 'web_search', args: {query: 'f1 winner'}}]);
    expect(result.flags.textFallback).toBe(1);
    expect(result.calls[0].fromText).toBe(true);
    expect(result.text).toBe('Norris won.');
  });

  it('runs the search itself when the gate forces one', async () => {
    const {list, log} = tools();
    const {engine, requests} = scriptedEngine([
      {content: 'Answer from results.'},
    ]);
    const result = await runToolTurn({
      ...base(engine, list, 'Any news on the EU AI Act this week?'),
      searchVerdict: {decision: 'force', reason: 'fresh_term'},
      directQueries: () => ['news EU AI Act November 2026'],
    });
    expect(log).toEqual([
      {name: 'web_search', args: {query: 'news EU AI Act November 2026'}},
    ]);
    expect(result.flags.forcedSearch).toBe(true);
    expect(result.steps).toBe(1);
    expect(requests[0].messages.slice(-2).map((m: any) => m.role)).toEqual([
      'assistant',
      'tool',
    ]);
    expect(result.calls[0]).toMatchObject({synthetic: true, status: 'ok'});
  });

  it('keeps the tool list but sets tool_choice none for a turn that needs no tool', async () => {
    const {list, log} = tools();
    const {engine, requests} = scriptedEngine([{content: 'Hello!'}]);
    const result = await runToolTurn({
      ...base(engine, list, 'hi'),
      searchVerdict: {
        decision: 'none',
        reason: 'conversational',
        abstainAll: true,
      },
    });
    expect(requests[0].tool_choice).toBe('none');
    expect(requests[0].tools).toHaveLength(2);
    expect(log).toEqual([]);
    expect(result.text).toBe('Hello!');
  });

  it('drops the tools and retries when a model prints a call although none was allowed', async () => {
    const {list, log} = tools();
    const {engine, requests} = scriptedEngine([
      {
        content:
          '<tool_call>{"name": "web_search", "arguments": {"query": "17 times 23"}}</tool_call>',
      },
      {content: '391'},
    ]);
    const result = await runToolTurn({
      ...base(engine, list, 'What is 17 times 23?'),
      searchVerdict: {decision: 'none', reason: 'stable_task'},
    });
    expect(result.flags.markupRetry).toBe(true);
    expect(requests[1].tools).toBeUndefined();
    expect(log).toEqual([]);
    expect(result.text).toBe('391');
  });

  it('asks once more when the answer after a tool result is empty', async () => {
    const {list} = tools();
    const {engine, requests} = scriptedEngine([
      {calls: [{name: 'web_search', args: {query: 'brenner pass'}}]},
      {content: ''},
      {content: 'The pass is open.'},
    ]);
    const result = await runToolTurn(base(engine, list, 'is it open?'));
    expect(result.flags.emptyRetry).toBe(true);
    expect(requests[2].messages.at(-1).content).toContain('Answer the user');
    expect(result.text).toBe('The pass is open.');
  });

  it('nudges once when the model says it sent something no tool sent', async () => {
    const {list, log} = tools();
    const {engine} = scriptedEngine([
      {content: "I've sent the email to Anna."},
      {
        calls: [
          {
            name: 'email_send',
            args: {to: ['anna@example.com'], body: 'Running late'},
          },
        ],
      },
      {content: 'Sent.'},
    ]);
    const result = await runToolTurn(
      base(engine, list, 'email anna@example.com that I am late'),
    );
    expect(result.flags.actionNudge).toBe(true);
    expect(log).toHaveLength(1);
    expect(result.text).toBe('Sent.');
  });

  it('strips leaked thinking and control markup from the answer', async () => {
    const {list} = tools();
    const {engine} = scriptedEngine([
      {
        content:
          'The capital is Canberra.</think>The capital of Australia is **Canberra**.<|im_end|>',
      },
    ]);
    const result = await runToolTurn(
      base(engine, list, 'capital of Australia?'),
    );
    expect(result.text).not.toMatch(/think|im_end/);
    expect(result.text).toContain('Canberra');
  });

  it('reports a runaway instead of an answer', async () => {
    const {list} = tools();
    const {engine} = scriptedEngine([
      {content: `List:\n${'- same line\n'.repeat(60)}`, truncated: true},
    ]);
    const result = await runToolTurn(base(engine, list, 'list things'));
    expect(result.stopReason).toBe('runaway');
  });

  it('limits calls per step and re-resolves tools between steps', async () => {
    const {list, log} = tools();
    const {engine, requests} = scriptedEngine([
      {
        calls: [
          {name: 'web_search', args: {query: 'one thing'}},
          {name: 'web_search', args: {query: 'another topic entirely'}},
          {name: 'web_search', args: {query: 'third unrelated subject'}},
        ],
      },
      {content: 'done'},
    ]);
    const result = await runToolTurn({
      ...base(engine, list, 'q'),
      policy: {...LOOP_POLICY.B, maxCallsPerStep: 2},
      resolveTools: () => [list[0]],
    });
    expect(log).toHaveLength(2);
    expect(requests[1].tools).toHaveLength(1);
    expect(result.text).toBe('done');
  });
});

describe('executeGuarded', () => {
  const guards = () => ({
    repair: new RepairState(),
    guard: new LoopGuard(LOOP_POLICY.B),
  });

  it('emits started and result events with the card and sources', async () => {
    const {list} = tools({
      web_search: async () => ({
        text: 'block',
        card: {type: 'sources', query: 'q', count: 1},
        sources: [{url: 'https://a.example/', title: 'A', site: 'a.example'}],
      }),
    });
    const events: ToolEvent[] = [];
    const stop = subscribeToolEvents(event => events.push(event));
    const result = await executeGuarded({
      callId: 'c1',
      turnId: 't1',
      name: 'web_search',
      rawArguments: '{"query": "q"}',
      offered: list,
      guards: guards(),
      context: {now},
    });
    stop();
    expect(result.status).toBe('ok');
    expect(events.map(event => event.type)).toEqual(['started', 'result']);
    expect(events[0]).toMatchObject({
      label: 'Searching the web',
      args: {query: 'q'},
      turnId: 't1',
    });
    expect(events[1]).toMatchObject({
      card: {type: 'sources'},
      sources: [{site: 'a.example'}],
    });
  });

  it('turns a thrown tool into an error result, not a crash', async () => {
    const {list} = tools({
      web_search: async () => {
        throw new Error('socket hang up');
      },
    });
    const result = await executeGuarded({
      callId: 'c1',
      turnId: 't1',
      name: 'web_search',
      rawArguments: {query: 'q'},
      offered: list,
      guards: guards(),
      context: {now},
    });
    expect(result).toMatchObject({status: 'tool_error'});
    expect(result.content).toContain('web_search failed: socket hang up');
  });

  it('caps a long result and keeps the closing rules of a results block', () => {
    expect(capResult('a'.repeat(50), 100)).toBe('a'.repeat(50));
    const capped = capResult(`${'Sentence one. '.repeat(40)}`, 200);
    expect(capped.length).toBeLessThan(260);
    expect(capped).toContain('[cut:');
    const block = `<web_results>\n${'[1] text line.\n'.repeat(80)}\n\nAnswer from these sources only.\n</web_results>`;
    const cut = capResult(block, 400);
    expect(cut.endsWith('</web_results>')).toBe(true);
    expect(cut).toContain('Answer from these sources only.');
    expect(cut.length).toBeLessThan(520);
  });
});

describe('talent adapter', () => {
  afterEach(() => endTurn());

  it('exposes a tool to upstream with guards that hold across the turn', async () => {
    const {list, log} = tools();
    const talent = asTalentEngine(list[0]);
    expect(talent.toToolDefinition().function.name).toBe('web_search');
    beginTurn({
      turnId: 't9',
      guards: {repair: new RepairState(), guard: new LoopGuard(LOOP_POLICY.B)},
      offered: list,
      context: {now},
    });
    const bad = await talent.execute({});
    expect(bad.type).toBe('error');
    expect(bad.summary).toContain(
      '[System Notice] The call to web_search was not run',
    );
    const good = await talent.execute({query: 'x'});
    expect(good).toMatchObject({type: 'text'});
    const again = await talent.execute({query: 'x'});
    expect(again.summary).toContain('Duplicate call skipped');
    const secondBad = await talent.execute({});
    expect(secondBad.summary).toContain('Do not call any more tools');
    expect(log).toHaveLength(1);
  });

  it('returns structured search results for upstream cards', async () => {
    const {list} = tools({
      web_search: async () => ({
        text: '<web_results>…</web_results>',
        sources: [
          {
            url: 'https://a.example/x',
            title: 'A',
            site: 'a.example',
            snippet: 's',
          },
        ],
      }),
    });
    const result = await asTalentEngine(list[0]).execute({query: 'q'});
    expect(result).toEqual({
      type: 'search',
      query: 'q',
      results: [{title: 'A', url: 'https://a.example/x', snippet: 's'}],
      summary: '<web_results>…</web_results>',
    });
  });
});
