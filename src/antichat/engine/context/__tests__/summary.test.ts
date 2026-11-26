import type {ChatMessage} from '../../prompt/types';
import {buildContinuation, seedContinuation} from '../continuation';
import {subscribeContextEvents, type ContextEvent} from '../events';
import {fingerprint} from '../fit';
import {
  SUMMARY_SYSTEM_PROMPT,
  buildSummaryMessages,
  capFacts,
  mergeFacts,
  parseSummary,
  renderSummaryText,
  renderTranscript,
  summarizeMessages,
} from '../summary';
import {
  createMemoryContextStateStore,
  createPersistentContextStateStore,
  emptyContextState,
  getContextStateStore,
  setContextStateStore,
} from '../summaryStore';
import {
  createEstimatingCounter,
  createLlamaTokenCounter,
  estimateTokens,
  messageText,
  withTokenCache,
} from '../tokenCounter';
import {createFakeEngine, filler} from './support/fakeEngine';

jest.mock('@react-native-async-storage/async-storage', () => {
  const data = new Map<string, string>();
  return {
    __esModule: true,
    default: {
      getItem: jest.fn(async (key: string) => data.get(key) ?? null),
      setItem: jest.fn(async (key: string, value: string) => {
        data.set(key, value);
      }),
      removeItem: jest.fn(async (key: string) => {
        data.delete(key);
      }),
    },
  };
});

const counter = createEstimatingCounter();

describe('parseSummary', () => {
  it('reads the FACTS / SUMMARY form', () => {
    expect(
      parseSummary(
        'FACTS:\n- The user is called Marisol\n- Her dog Biscuit is a beagle\nSUMMARY:\nThey talked about basil.\nShe wants a watering plan.',
      ),
    ).toEqual({
      facts: ['The user is called Marisol', 'Her dog Biscuit is a beagle'],
      summary: 'They talked about basil. She wants a watering plan.',
    });
  });

  it('tolerates markdown headers, numbering and inline content', () => {
    expect(
      parseSummary(
        '**Facts:**\n1. Lives in Graz\n* Allergic to peanuts\n\n## Summary: Short chat about soup.',
      ),
    ).toEqual({
      facts: ['Lives in Graz', 'Allergic to peanuts'],
      summary: 'Short chat about soup.',
    });
  });

  it('drops echoes of the instructions and caps the facts of one pass', () => {
    const many = Array.from(
      {length: 12},
      (_, i) => `- Fact number ${i} about gardening`,
    ).join('\n');
    const parsed = parseSummary(
      `FACTS:\n- one lasting fact per line: ...\n- ... (lines)\n- ok\n${many}\nSUMMARY:\nS.`,
    );
    expect(parsed.facts).toHaveLength(8);
    expect(parsed.facts[0]).toBe('Fact number 0 about gardening');
  });

  it('reads replies without headers: bullets are facts, the rest is narrative', () => {
    expect(
      parseSummary(
        '- User name: Marisol\n- User dog: Biscuit (4-year-old Beagle)\n- User dog: Biscuit (4-year-old Beagle)\nThey talked about soup.\nThey talked about soup.',
      ),
    ).toEqual({
      facts: ['User name: Marisol', 'User dog: Biscuit (4-year-old Beagle)'],
      summary: 'They talked about soup.',
    });
  });

  it('cleans double bullets and quotes, and drops a fact cut off by the token limit', () => {
    const raw =
      'FACTS:\n- "- Marisol is the user\'s name."\n- list\n- "- none" (no specific details)\n- She lives in Graz.\n- User is allergic to pean';
    expect(parseSummary(raw, true).facts).toEqual([
      "Marisol is the user's name.",
      'She lives in Graz.',
    ]);
    expect(parseSummary(raw, false).facts).toHaveLength(3);
  });

  it('treats "none" as no facts and plain prose as the narrative', () => {
    expect(parseSummary('FACTS:\n- none\nSUMMARY:\nSmall talk.')).toEqual({
      facts: [],
      summary: 'Small talk.',
    });
    expect(parseSummary('They discussed stretching.')).toEqual({
      facts: [],
      summary: 'They discussed stretching.',
    });
    expect(parseSummary('')).toEqual({facts: [], summary: ''});
  });
});

describe('facts', () => {
  it('only ever adds: repeats and contained facts are skipped', () => {
    const merged = mergeFacts(
      ['The dog is called Biscuit, a beagle', 'Lives in Graz'],
      [
        'the dog is called Biscuit',
        'Lives in Graz.',
        'Allergic to peanuts',
        '',
      ],
    );
    expect(merged).toEqual([
      'The dog is called Biscuit, a beagle',
      'Lives in Graz',
      'Allergic to peanuts',
    ]);
  });

  it('keeps what the user asked to be remembered, not what they asked about', () => {
    expect(
      mergeFacts(
        [],
        [
          'User asked about how compound interest works.',
          'User asked for advice on keeping basil alive',
          'User asked to remember that the dog is called Biscuit',
          "User's name is Marisol.",
          'Name: Marisol',
        ],
      ),
    ).toEqual([
      'User asked to remember that the dog is called Biscuit',
      "User's name is Marisol.",
    ]);
  });

  it('caps by dropping the newest facts first', async () => {
    const facts = Array.from(
      {length: 30},
      (_, i) => `Fact number ${i} ${filler(i, 6)}`,
    );
    const capped = await capFacts(facts, 80, counter);
    expect(capped.length).toBeLessThan(30);
    expect(capped[0]).toBe(facts[0]);
    expect(
      await counter.countText(capped.map(f => `- ${f}`).join('\n')),
    ).toBeLessThanOrEqual(80);
  });

  it('renders facts and narrative for the prompt', () => {
    expect(renderSummaryText(['A', 'B'], 'Text.')).toBe(
      'Facts:\n- A\n- B\nSummary: Text.',
    );
    expect(renderSummaryText([], '')).toBe('');
  });
});

describe('renderTranscript', () => {
  it('labels roles, clips long turns, notes images, skips empty assistant turns', () => {
    const transcript = renderTranscript([
      {role: 'system', content: 'ignored'},
      {
        role: 'user',
        content: [
          {type: 'text', text: 'What is this?'},
          {type: 'image_url', image_url: {url: 'x'}},
        ],
      },
      {role: 'assistant', content: '', tool_calls: [{id: 'c'}]},
      {role: 'tool', content: 'r'.repeat(900)},
      {role: 'assistant', content: 'A cat.'},
    ]);
    expect(transcript).toBe(
      `[User]: What is this? [1 image]\n\n[Tool result]: ${'r'.repeat(600)}… [truncated]\n\n[Assistant]: A cat.`,
    );
  });
});

describe('summarizeMessages', () => {
  const messages: ChatMessage[] = [
    {role: 'user', content: 'Please remember that my dog is called Biscuit.'},
    {role: 'assistant', content: 'Noted.'},
    {role: 'user', content: 'Tell me about basil.'},
    {role: 'assistant', content: filler(1, 80)},
  ];

  it('asks the model with thinking off and merges new facts into the old', async () => {
    const engine = createFakeEngine();
    const result = await summarizeMessages({
      engine,
      messages,
      previousFacts: ['Lives in Graz'],
      previousSummary: 'Earlier small talk.',
      maxTokens: 400,
      nCtx: 4096,
      counter,
    });
    expect(result?.facts).toEqual([
      'Lives in Graz',
      'Please remember that my dog is called Biscuit.',
    ]);
    expect(result?.summary).toContain('The user asked 2 more questions');
    const call = engine.calls[0];
    expect(call.messages[0].content).toBe(SUMMARY_SYSTEM_PROMPT);
    // The earlier narrative is shown; the fact list is not (code keeps it).
    expect(call.messages[1].content).toContain(
      'Summary of what came before this excerpt:\nEarlier small talk.\n\nExcerpt of the chat:',
    );
    expect(call.messages[1].content).not.toContain('Lives in Graz');
    expect(call.params.enable_thinking).toBe(false);
    expect(call.params.n_predict).toBe(400);
  });

  it('summarises in several passes when the excerpt is larger than the window', async () => {
    const long: ChatMessage[] = [];
    for (let i = 0; i < 40; i++) {
      long.push({
        role: 'user',
        content:
          i === 1
            ? 'By the way, my dog is called Biscuit.'
            : `Q${i} ${filler(i, 40)}`,
      });
      long.push({role: 'assistant', content: filler(i + 100, 150)});
    }
    const engine = createFakeEngine();
    const result = await summarizeMessages({
      engine,
      messages: long,
      previousFacts: [],
      previousSummary: '',
      maxTokens: 300,
      nCtx: 4096,
      counter,
    });
    expect(engine.calls.length).toBeGreaterThan(1);
    expect(engine.calls.length).toBeLessThanOrEqual(4);
    for (const call of engine.calls) {
      expect(call.promptTokens).toBeLessThan(4096 - 300);
    }
    expect(result?.facts).toContain('By the way, my dog is called Biscuit.');
  });

  it('returns null when the model fails, and the old state when there is nothing to do', async () => {
    const engine = createFakeEngine();
    engine.failSummaries = true;
    const base = {
      engine,
      previousFacts: ['x'],
      previousSummary: 's',
      maxTokens: 300,
      nCtx: 4096,
      counter,
    };
    expect(await summarizeMessages({...base, messages})).toBeNull();
    expect(await summarizeMessages({...base, messages: []})).toEqual({
      facts: ['x'],
      summary: 's',
    });
  });

  it('builds the prompt with and without an earlier summary', () => {
    expect(buildSummaryMessages('T', '')[1].content).toBe(
      'Excerpt of the chat:\n---\nT\n---\n\nWrite FACTS and SUMMARY for this excerpt now.',
    );
  });
});

describe('continue in a new chat', () => {
  beforeEach(() => setContextStateStore(createMemoryContextStateStore()));

  const history: ChatMessage[] = [
    {role: 'user', content: 'My dog is called Biscuit.'},
    {role: 'assistant', content: 'Lovely name.'},
    {role: 'user', content: 'Tell me about basil.'},
    {role: 'assistant', content: 'Basil likes sun.'},
  ];

  it('folds the stored summary and the visible turns into one summary', async () => {
    const engine = createFakeEngine();
    await getContextStateStore().set('old', {
      ...emptyContextState(),
      facts: ['Lives in Graz'],
      summary: 'Earlier they planned a trip.',
      cutCount: 2,
      summarizedCount: 2,
      fingerprint: fingerprint(history.slice(0, 2)),
      compactions: 3,
    });
    const continuation = await buildContinuation({
      sessionId: 'old',
      messages: [{role: 'system', content: 'S'}, ...history],
      runtime: {engine, family: 'generic', nCtx: 4096, tokenCounter: counter},
    });
    expect(continuation?.facts).toEqual(['Lives in Graz']);
    expect(continuation?.summary).toContain('The user asked 1 more questions');
    // Only the part not yet summarised was sent to the model.
    expect(engine.calls[0].messages[1].content).not.toContain('Biscuit');
    expect(engine.calls[0].messages[1].content).toContain('basil');

    await seedContinuation('new', continuation!);
    const seeded = await getContextStateStore().get('new');
    expect(seeded).toMatchObject({
      cutCount: 0,
      carried: {facts: ['Lives in Graz'], fromSessionId: 'old'},
    });
  });

  it('summarises everything when nothing was stored, and gives up on an empty chat', async () => {
    const engine = createFakeEngine();
    const runtime = {
      engine,
      family: 'generic' as const,
      nCtx: 4096,
      tokenCounter: counter,
    };
    const continuation = await buildContinuation({messages: history, runtime});
    expect(continuation?.facts).toEqual(['My dog is called Biscuit.']);
    expect(continuation?.text).toContain('Facts:\n- My dog is called Biscuit.');
    expect(await buildContinuation({messages: [], runtime})).toBeNull();
  });
});

describe('stores, events and counters', () => {
  it('persists context state through AsyncStorage', async () => {
    const store = createPersistentContextStateStore();
    expect(await store.get('s')).toBeNull();
    const state = {...emptyContextState(), summary: 'x', cutCount: 4};
    await store.set('s', state);
    expect(await createPersistentContextStateStore().get('s')).toEqual(state);
    await store.delete('s');
    expect(await createPersistentContextStateStore().get('s')).toBeNull();
    const memory = createMemoryContextStateStore();
    await memory.set('a', state);
    await memory.delete('a');
    expect(await memory.get('a')).toBeNull();
  });

  it('delivers context events and survives a broken listener', () => {
    const {emitContextEvent} = require('../events');
    const seen: ContextEvent[] = [];
    const stopBad = subscribeContextEvents(() => {
      throw new Error('listener');
    });
    const stop = subscribeContextEvents(event => seen.push(event));
    emitContextEvent({type: 'compacting', sessionId: 's', active: true});
    stop();
    stopBad();
    emitContextEvent({type: 'compacting', sessionId: 's', active: false});
    expect(seen).toEqual([{type: 'compacting', sessionId: 's', active: true}]);
  });

  it('estimates dense scripts higher than Latin text', () => {
    expect(estimateTokens('')).toBe(0);
    expect(estimateTokens('hello world, this is text')).toBeLessThan(10);
    expect(estimateTokens('東京でおすすめのラーメン屋')).toBeGreaterThan(10);
  });

  it('reads text, images, tool calls and reasoning from a message', () => {
    expect(
      messageText({
        role: 'assistant',
        content: [
          {type: 'text', text: 'a'},
          {type: 'image_url'},
          {type: 'image'},
        ],
        tool_calls: [{id: 1}],
        reasoning_content: 'r',
      }),
    ).toEqual({text: 'a[{"id":1}]r', images: 2});
    expect(messageText({role: 'user'})).toEqual({text: '', images: 0});
  });

  it('counts with the model, charges images, and falls back on errors', async () => {
    const context = {
      tokenize: jest.fn(async (text: string) => ({
        tokens: [...text].map((_, i) => i),
      })),
      getFormattedChat: jest.fn(
        async (
          messages: ChatMessage[],
          _t: unknown,
          params: Record<string, unknown>,
        ) => ({
          prompt: `${messages.map(m => JSON.stringify(m.content)).join('|')}${params.tools ? 'TOOLS' : ''}`,
        }),
      ),
    };
    const llama = createLlamaTokenCounter(context as never);
    expect(await llama.countText('abcd')).toBe(4);
    expect(await llama.countText('')).toBe(0);
    const withImage = await llama.countPrompt([
      {
        role: 'user',
        content: [
          {type: 'text', text: 'hi'},
          {type: 'image_url', image_url: {url: 'u'}},
        ],
      },
    ]);
    expect(withImage).toBeGreaterThan(512);
    expect(context.getFormattedChat.mock.calls[0][0][0].content).toEqual([
      {type: 'text', text: 'hi'},
    ]);
    await llama.countPrompt(
      [{role: 'user', content: 'x'}],
      [{type: 'function'} as never],
    );
    expect(context.getFormattedChat.mock.calls[1][2]).toMatchObject({
      jinja: true,
      tools: [{type: 'function'}],
    });

    context.tokenize.mockRejectedValue(new Error('no context'));
    expect(await llama.countText('abcd efgh')).toBe(
      estimateTokens('abcd efgh'),
    );
    expect(
      await llama.countPrompt([{role: 'user', content: 'abcd'}]),
    ).toBeGreaterThan(0);
  });

  it('caches text counts with a bound', async () => {
    const inner = {
      exact: true,
      countText: jest.fn(async (t: string) => t.length),
      countPrompt: jest.fn(async () => 1),
    };
    const cached = withTokenCache(inner, 2);
    await cached.countText('a');
    await cached.countText('a');
    await cached.countText('bb');
    await cached.countText('ccc');
    await cached.countText('a');
    expect(inner.countText).toHaveBeenCalledTimes(4);
    expect(cached.exact).toBe(true);
  });
});
