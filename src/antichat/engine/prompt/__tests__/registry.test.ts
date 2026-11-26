import {createEstimatingCounter} from '../../context/tokenCounter';
import {
  appendTurnContext,
  clearRequestProviders,
  composeSystemText,
  hasRequestProviders,
  listRequestProviders,
  prepareRequest,
  registerRequestProvider,
  unregisterRequestProvider,
} from '../registry';
import type {ChatMessage, ToolDefinition} from '../types';

const tool = (name: string): ToolDefinition =>
  ({
    type: 'function',
    function: {name, description: name, parameters: {}},
  }) as ToolDefinition;

const messages: ChatMessage[] = [
  {role: 'system', content: 'Pal prompt.'},
  {role: 'user', content: 'Hello'},
  {role: 'assistant', content: 'Hi!'},
  {role: 'user', content: 'What time is it?'},
];

describe('prepareRequest', () => {
  beforeEach(() => clearRequestProviders());
  afterAll(() => clearRequestProviders());

  it('returns the very same objects when no provider is registered', async () => {
    const tools = [tool('web_search')];
    const params = {temperature: 0.4};
    const result = await prepareRequest({messages, session: {}, tools, params});
    expect(hasRequestProviders()).toBe(false);
    expect(result.changed).toBe(false);
    expect(result.messages).toBe(messages);
    expect(result.tools).toBe(tools);
    expect(result.params).toBe(params);
  });

  it('leaves the request content unchanged when providers contribute nothing', async () => {
    registerRequestProvider({id: 'quiet', contribute: () => undefined});
    const result = await prepareRequest({messages, session: {}});
    expect(result.changed).toBe(true);
    expect(result.messages).toEqual(messages);
    expect(result.tools).toEqual([]);
  });

  it('builds one system message: stable blocks, upstream text, session blocks', async () => {
    registerRequestProvider({
      id: 'b',
      order: 20,
      contribute: () => ({
        systemBlocks: [
          {
            id: 'memory',
            slot: 'session',
            order: 50,
            text: 'Memory: likes tea.',
          },
          {id: 'style', slot: 'stable', order: 30, text: 'Be brief.'},
        ],
      }),
    });
    registerRequestProvider({
      id: 'a',
      order: 10,
      contribute: () => ({
        systemBlocks: [
          {id: 'date', slot: 'session', order: 10, text: 'Current date: X.'},
          {id: 'base', slot: 'stable', order: 10, text: 'You are AntiChat.'},
          {id: 'empty', slot: 'stable', text: '   '},
        ],
      }),
    });
    const result = await prepareRequest({messages, session: {}});
    expect(result.messages[0]).toEqual({
      role: 'system',
      content:
        'You are AntiChat.\n\nBe brief.\n\nPal prompt.\n\nCurrent date: X.\n\nMemory: likes tea.',
    });
    expect(result.messages.filter(m => m.role === 'system')).toHaveLength(1);
    expect(result.messages.slice(1)).toEqual(messages.slice(1));
    expect(listRequestProviders().map(p => p.id)).toEqual(['a', 'b']);
  });

  it('creates the system message when upstream had none', async () => {
    registerRequestProvider({
      id: 'a',
      contribute: () => ({
        systemBlocks: [{id: 'base', slot: 'stable', text: 'Base.'}],
      }),
    });
    const result = await prepareRequest({
      messages: [{role: 'user', content: 'Hi'}],
      session: {},
    });
    expect(result.messages).toEqual([
      {role: 'system', content: 'Base.'},
      {role: 'user', content: 'Hi'},
    ]);
  });

  it("drops the model's default system prompt when AntiChat supplies the base", async () => {
    registerRequestProvider({
      id: 'a',
      contribute: () => ({
        systemBlocks: [{id: 'base', slot: 'stable', text: 'Base.'}],
      }),
    });
    const result = await prepareRequest({
      messages: [
        {
          role: 'system',
          content: 'You are a helpful assistant.\n\nSearch rules.',
        },
        {role: 'user', content: 'Hi'},
      ],
      session: {},
      runtime: {modelDefaultSystemPrompt: 'You are a helpful assistant.'},
    });
    expect(result.messages[0].content).toBe('Base.\n\nSearch rules.');
  });

  it('appends turn context to the newest user message only', async () => {
    registerRequestProvider({
      id: 'clock',
      contribute: ({userText}) =>
        userText.includes('time')
          ? {turnContext: ['Current local time: 14:05.']}
          : undefined,
    });
    const result = await prepareRequest({messages, session: {}});
    expect(result.messages[3].content).toBe(
      'What time is it?\n\n[Current local time: 14:05.]',
    );
    expect(result.messages[1]).toBe(messages[1]);
    expect(messages[3].content).toBe('What time is it?');
  });

  it('appends turn context to multimodal content', () => {
    const out = appendTurnContext(
      [
        {
          role: 'user',
          content: [
            {type: 'text', text: 'Look'},
            {type: 'image_url', image_url: {url: 'file://a.jpg'}},
          ],
        },
      ],
      ['Note.'],
    );
    expect((out[0].content as Array<{text?: string}>)[0].text).toBe(
      'Look\n\n[Note.]',
    );
    expect(
      appendTurnContext([{role: 'assistant', content: 'x'}], ['n']),
    ).toEqual([{role: 'assistant', content: 'x'}]);
    expect(appendTurnContext(messages, ['  '])).toBe(messages);
  });

  it('merges tools: request tools first, additions deduplicated, removals applied', async () => {
    registerRequestProvider({
      id: 'tools',
      contribute: () => ({
        tools: [tool('calculator'), tool('web_search'), tool('weather')],
        removeTools: ['weather'],
      }),
    });
    const result = await prepareRequest({
      messages,
      session: {},
      tools: [tool('web_search'), tool('read_url')],
    });
    expect(result.tools.map(t => t.function.name)).toEqual([
      'web_search',
      'read_url',
      'calculator',
    ]);
  });

  it('merges params in provider order, template kwargs deeply', async () => {
    registerRequestProvider({
      id: 'p1',
      order: 1,
      contribute: () => ({
        params: {
          temperature: 0.7,
          chat_template_kwargs: {enable_thinking: false},
        },
      }),
    });
    registerRequestProvider({
      id: 'p2',
      order: 2,
      contribute: () => ({
        params: {
          temperature: 0.2,
          chat_template_kwargs: {reasoning_effort: 'low'},
        },
      }),
    });
    const result = await prepareRequest({
      messages,
      session: {},
      params: {top_k: 40, chat_template_kwargs: {custom: 1}} as never,
    });
    expect(result.params).toEqual({
      top_k: 40,
      temperature: 0.2,
      chat_template_kwargs: {
        custom: 1,
        enable_thinking: false,
        reasoning_effort: 'low',
      },
    });
  });

  it('runs transforms after contributions and collects meta', async () => {
    registerRequestProvider({
      id: 'late',
      order: 900,
      transform: draft => ({
        ...draft,
        messages: draft.messages.slice(-1),
        meta: {...draft.meta, trimmed: true},
      }),
    });
    registerRequestProvider({
      id: 'early',
      order: 1,
      contribute: () => ({
        systemBlocks: [{id: 'b', slot: 'stable', text: 'B'}],
        meta: {memoriesUsed: ['m1']},
      }),
    });
    const result = await prepareRequest({messages, session: {}});
    expect(result.messages).toEqual([messages[3]]);
    expect(result.meta).toEqual({memoriesUsed: ['m1'], trimmed: true});
  });

  it('skips a provider that throws and still sends', async () => {
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {});
    registerRequestProvider({
      id: 'broken',
      contribute: () => {
        throw new Error('boom');
      },
      transform: () => {
        throw new Error('boom');
      },
    });
    registerRequestProvider({
      id: 'ok',
      contribute: () => ({
        systemBlocks: [{id: 'b', slot: 'stable', text: 'B'}],
      }),
    });
    const result = await prepareRequest({messages, session: {}});
    expect(result.messages[0].content).toBe('B\n\nPal prompt.');
    expect(warn).toHaveBeenCalledTimes(2);
    warn.mockRestore();
  });

  it('gives providers the runtime, with defaults filled in', async () => {
    const seen: unknown[] = [];
    registerRequestProvider({
      id: 'spy',
      contribute: context => {
        seen.push(context.runtime, context.userText);
      },
    });
    const counter = createEstimatingCounter();
    await prepareRequest({
      messages,
      session: {id: 's1'},
      runtime: {nCtx: 8192, family: 'gemma4', tokenCounter: counter},
    });
    expect(seen[0]).toMatchObject({
      nCtx: 8192,
      family: 'gemma4',
      deviceClass: 'B',
      tokenCounter: counter,
    });
    expect(seen[1]).toBe('What time is it?');
    await prepareRequest({messages, session: {}});
    expect(seen[2]).toMatchObject({nCtx: 4096, family: 'generic'});
  });

  it('registers, replaces and removes providers', () => {
    const remove = registerRequestProvider({id: 'x'});
    const replacement = {id: 'x', order: 5};
    registerRequestProvider(replacement);
    remove(); // the stale handle must not remove the replacement
    expect(listRequestProviders()).toEqual([replacement]);
    unregisterRequestProvider('x');
    expect(hasRequestProviders()).toBe(false);
  });

  it('composeSystemText ignores duplicate block ids', () => {
    expect(
      composeSystemText(
        [
          {id: 'a', slot: 'stable', text: 'One'},
          {id: 'a', slot: 'stable', text: 'Two'},
        ],
        '',
      ),
    ).toBe('One');
  });
});
