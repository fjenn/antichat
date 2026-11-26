import {validateArguments} from '../schema';
import {
  MAX_REPAIRS,
  RepairState,
  checkCall,
  parseArguments,
  repairPrompt,
} from '../repair';
import {
  hasToolCallMarkup,
  parsePythonArgs,
  parseToolCallsFromText,
} from '../textFallback';
import {
  BUDGET_NOTICE,
  DUPLICATE_NOTICE,
  LOOP_POLICY,
  LoopGuard,
  callKey,
  looksRunaway,
} from '../loopGuard';
import {trimDescription} from '../types';

const schema = {
  type: 'object',
  properties: {
    query: {type: 'string', minLength: 1},
    recency_days: {type: 'integer', minimum: 1, maximum: 365},
    tags: {type: 'array', items: {type: 'string'}},
    mode: {type: 'string', enum: ['fast', 'deep']},
    exact: {type: 'boolean'},
  },
  required: ['query'],
  additionalProperties: false,
};

describe('argument validation', () => {
  it('accepts a valid call unchanged', () => {
    const result = validateArguments({query: 'a', recency_days: 7}, schema);
    expect(result).toMatchObject({
      ok: true,
      value: {query: 'a', recency_days: 7},
      fixes: [],
    });
  });

  it('coerces the slips that have one meaning', () => {
    const result = validateArguments(
      {
        Query: 'x',
        recency_days: '14',
        tags: 'news',
        mode: 'FAST',
        exact: 'true',
        extra: 1,
      },
      schema,
    );
    expect(result.ok).toBe(true);
    expect(result.value).toEqual({
      query: 'x',
      recency_days: 14,
      tags: ['news'],
      mode: 'fast',
      exact: true,
    });
    expect(result.fixes.join(' | ')).toContain(
      'unknown argument extra dropped',
    );
  });

  it('drops null and blank optional arguments', () => {
    const result = validateArguments(
      {query: 'x', recency_days: null, tags: ''},
      schema,
    );
    expect(result).toMatchObject({ok: true, value: {query: 'x'}});
  });

  it('reports what is wrong in words the model can act on', () => {
    expect(validateArguments({}, schema).problems).toEqual([
      'missing required argument "query"',
    ]);
    expect(validateArguments({query: '  '}, schema).problems[0]).toBe(
      'required argument "query" is empty',
    );
    expect(
      validateArguments({query: 'x', recency_days: 900}, schema).problems,
    ).toEqual(['recency_days must be at most 365']);
    expect(
      validateArguments({query: 'x', mode: 'slow'}, schema).problems[0],
    ).toContain('mode must be one of "fast", "deep"');
    expect(validateArguments({query: {a: 1}}, schema).problems[0]).toBe(
      'query must be text, got object',
    );
    expect(validateArguments('nope', schema).ok).toBe(false);
  });

  it('validates nested objects and arrays', () => {
    const nested = {
      type: 'object',
      properties: {
        to: {type: 'array', items: {type: 'string'}},
        event: {
          type: 'object',
          properties: {title: {type: 'string'}, minutes: {type: 'integer'}},
          required: ['title'],
        },
      },
      required: ['to'],
    };
    expect(
      validateArguments({to: 'a@b.c, d@e.f', event: {minutes: '30'}}, nested),
    ).toMatchObject({
      ok: false,
      problems: ['missing required argument "event.title"'],
    });
    expect(
      validateArguments(
        {to: ['a@b.c'], event: '{"title": "Call", "minutes": 30}'},
        nested,
      ),
    ).toMatchObject({
      ok: true,
      value: {to: ['a@b.c'], event: {title: 'Call', minutes: 30}},
    });
  });
});

describe('argument parsing and repair', () => {
  it('parses clean, broken and double-encoded JSON', () => {
    expect(parseArguments('{"a": 1}')).toEqual({
      ok: true,
      value: {a: 1},
      repaired: false,
    });
    expect(parseArguments("{'a': 1, b: 'x',}")).toEqual({
      ok: true,
      value: {a: 1, b: 'x'},
      repaired: true,
    });
    expect(parseArguments('{"query": "tesla price"')).toMatchObject({
      ok: true,
      value: {query: 'tesla price'},
      repaired: true,
    });
    expect(parseArguments('"{\\"a\\": 2}"')).toMatchObject({
      ok: true,
      value: {a: 2},
    });
    expect(parseArguments('')).toMatchObject({ok: true, value: {}});
    expect(parseArguments({a: 3})).toMatchObject({ok: true, value: {a: 3}});
    expect(parseArguments('[1, 2]').ok).toBe(false);
  });

  const offered = [
    {
      name: 'web_search',
      parameters: schema,
      normalize: (args: Record<string, unknown>) =>
        args.q !== undefined ? {query: args.q} : args,
    },
  ];
  const context = {now: new Date(2026, 10, 24)};

  it('checks a call: unknown tool, bad JSON, schema, normaliser', () => {
    expect(checkCall('search', '{}', offered, context)).toMatchObject({
      ok: false,
      kind: 'unknown_tool',
      problem: 'there is no tool named "search"; the tools are: web_search',
    });
    expect(
      checkCall('web_search', 'not json at all [', offered, context),
    ).toMatchObject({
      ok: false,
      kind: 'bad_json',
    });
    expect(checkCall('web_search', '{}', offered, context)).toMatchObject({
      ok: false,
      kind: 'schema',
      problem:
        'the arguments do not match the schema: missing required argument "query"',
    });
    expect(
      checkCall('web_search', '{"q": "weather"}', offered, context),
    ).toMatchObject({
      ok: true,
      args: {query: 'weather'},
    });
  });

  it('allows exactly one repair prompt per turn', () => {
    const state = new RepairState();
    const first = state.onMalformed(
      'web_search',
      'missing required argument "query"',
    );
    expect(first).toEqual({
      action: 'repair',
      prompt:
        '[System Notice] The call to web_search was not run: missing required argument "query". Call it again with arguments that match its schema, or answer without it.',
    });
    expect(state.onMalformed('web_search', 'again')).toEqual({
      action: 'final_answer',
    });
    expect(state.repairsUsed).toBe(MAX_REPAIRS);
    expect(repairPrompt('x', 'bad', {a: 1})).toContain(
      'A minimal valid call looks like this: {"a":1}',
    );
  });
});

describe('text-fallback parsing', () => {
  const known = ['web_search', 'read_url', 'calendar_create_event'];

  it('reads Hermes / Qwen blocks, closed and cut off', () => {
    const closed = parseToolCallsFromText(
      'Let me check.\n<tool_call>\n{"name": "web_search", "arguments": {"query": "lisbon weather"}}\n</tool_call>',
      known,
    );
    expect(closed.calls).toHaveLength(1);
    expect(closed.calls[0]).toMatchObject({name: 'web_search'});
    expect(JSON.parse(closed.calls[0].argumentsText)).toEqual({
      query: 'lisbon weather',
    });
    expect(closed.text).toBe('Let me check.');
    const open = parseToolCallsFromText(
      '<tool_call>{"name": "read_url", "arguments": {"url": "https://a.b"}',
      known,
    );
    expect(open.calls[0].name).toBe('read_url');
  });

  it('reads Qwen XML, Gemma and LFM formats', () => {
    const xml = parseToolCallsFromText(
      '<tool_call>\n<function=web_search>\n<parameter=query>\nf1 winner\n</parameter>\n</function>\n</tool_call>',
      known,
    );
    expect(JSON.parse(xml.calls[0].argumentsText)).toEqual({
      query: 'f1 winner',
    });

    const gemma = parseToolCallsFromText(
      '<|tool_call>call:web_search{query:<|"|>EU AI Act news<|"|>,recency_days:7}<tool_call|>',
      known,
    );
    expect(gemma.calls[0].name).toBe('web_search');
    expect(JSON.parse(gemma.calls[0].argumentsText)).toEqual({
      query: 'EU AI Act news',
      recency_days: 7,
    });

    const lfm = parseToolCallsFromText(
      '<|tool_call_start|>[calendar_create_event(title="Lunch, with Maria", start="2026-11-27T12:30:00", attendees=["a@b.c"], all_day=False)]<|tool_call_end|>',
      known,
    );
    expect(lfm.calls[0].name).toBe('calendar_create_event');
    expect(JSON.parse(lfm.calls[0].argumentsText)).toEqual({
      title: 'Lunch, with Maria',
      start: '2026-11-27T12:30:00',
      attendees: ['a@b.c'],
      all_day: false,
    });
    expect(lfm.text).toBe('');
  });

  it('reads fenced and bare JSON only for offered tools', () => {
    const fenced = parseToolCallsFromText(
      '```json\n{"name": "web_search", "parameters": {"query": "x"}}\n```',
      known,
    );
    expect(fenced.calls).toHaveLength(1);
    const bare = parseToolCallsFromText(
      '{"tool": "read_url", "args": {"url": "https://a.b"}}',
      known,
    );
    expect(bare.calls[0].name).toBe('read_url');
    const python = parseToolCallsFromText(
      'web_search(query="best ramen munich")',
      known,
    );
    expect(JSON.parse(python.calls[0].argumentsText)).toEqual({
      query: 'best ramen munich',
    });
  });

  it('never mistakes an answer that shows JSON or code for a call', () => {
    const answer =
      'Here is an example config:\n```json\n{"name": "my-app", "version": "1.0.0"}\n```\nPut it in package.json and run the install.';
    expect(parseToolCallsFromText(answer, known)).toEqual({
      calls: [],
      text: answer,
    });
    expect(
      parseToolCallsFromText('{"name": "web_search", "arguments": {}}', [])
        .calls,
    ).toEqual([]);
    expect(
      parseToolCallsFromText('Use print(x) to debug.', known).calls,
    ).toEqual([]);
    expect(hasToolCallMarkup('plain text')).toBe(false);
    expect(hasToolCallMarkup('<tool_call>')).toBe(true);
  });

  it('parses Python argument lists', () => {
    expect(
      parsePythonArgs('a="x, y", n=3, f=1.5, ok=True, none=None, l=[1, 2]'),
    ).toEqual({
      a: 'x, y',
      n: 3,
      f: 1.5,
      ok: true,
      none: null,
      l: [1, 2],
    });
  });
});

describe('loop guard', () => {
  it('skips an identical call and says so', () => {
    const guard = new LoopGuard(LOOP_POLICY.B);
    expect(guard.admit('web_search', {query: 'Lisbon weather'})).toEqual({
      action: 'run',
    });
    expect(guard.admit('web_search', {query: 'lisbon  WEATHER'})).toEqual({
      action: 'skip',
      reason: 'duplicate',
      notice: DUPLICATE_NOTICE,
    });
    expect(callKey('a', {y: 1, x: 'B'})).toBe(callKey('a', {x: 'b', y: 1}));
  });

  it('stops near-identical repeats and enforces the call budget', () => {
    const guard = new LoopGuard({
      maxSteps: 3,
      maxCalls: 4,
      maxCallsPerStep: 2,
      maxSimilarCalls: 2,
    });
    const search = (query: string) => guard.admit('web_search', {query});
    expect(search('tesla model y price germany').action).toBe('run');
    expect(search('germany tesla model y price').action).toBe('run');
    expect(search('price of tesla model y germany')).toMatchObject({
      action: 'skip',
      reason: 'similar',
    });
    expect(guard.admit('read_url', {url: 'https://a.b/1'}).action).toBe('run');
    expect(guard.admit('read_url', {url: 'https://c.d/2'}).action).toBe('run');
    expect(guard.admit('read_url', {url: 'https://e.f/3'})).toEqual({
      action: 'skip',
      reason: 'budget',
      notice: BUDGET_NOTICE,
    });
    expect(guard.callsUsed).toBe(4);
  });

  it('counts steps', () => {
    const guard = new LoopGuard({
      maxSteps: 2,
      maxCalls: 9,
      maxCallsPerStep: 2,
      maxSimilarCalls: 2,
    });
    expect(guard.beginStep()).toBe(true);
    expect(guard.lastStep).toBe(false);
    expect(guard.beginStep()).toBe(true);
    expect(guard.lastStep).toBe(true);
    expect(guard.beginStep()).toBe(false);
  });

  it('recognises runaway text', () => {
    expect(looksRunaway('A normal answer. '.repeat(3))).toBe(false);
    expect(looksRunaway(`Intro\n${'- item one\n'.repeat(40)}`)).toBe(true);
    expect(looksRunaway(`x${'1,000,'.repeat(80)}`)).toBe(true);
    const prose = Array.from(
      {length: 40},
      (_, i) => `Sentence number ${i} says something new.`,
    ).join(' ');
    expect(looksRunaway(prose)).toBe(false);
  });
});

describe('tool descriptions', () => {
  it('are trimmed to the first sentence within 180 characters', () => {
    const long = `${'Search the web for current information. '.repeat(2)}${'Use it for many things. '.repeat(10)}`;
    const trimmed = trimDescription(long);
    expect(trimmed.length).toBeLessThanOrEqual(180);
    expect(trimmed.endsWith('.')).toBe(true);
    expect(trimDescription('Short.')).toBe('Short.');
  });
});
