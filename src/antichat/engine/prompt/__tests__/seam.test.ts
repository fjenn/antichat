import {chatSessionStore, modelStore} from '../../../../store';
import type {ApiCompletionParams} from '../../../../utils/completionTypes';
import {clearRequestProviders, registerRequestProvider} from '../registry';
import {
  applyRequestSeam,
  getLastSentRequest,
  resolveSeamRuntime,
  setSeamEnvironment,
} from '../seam';
import type {RequestContext, ToolDefinition} from '../types';

const tool = (name: string): ToolDefinition =>
  ({
    type: 'function',
    function: {name, description: name, parameters: {}},
  }) as ToolDefinition;

const makeParams = (): ApiCompletionParams =>
  ({
    messages: [
      {role: 'system', content: 'Pal prompt.'},
      {role: 'user', content: 'Hello'},
    ],
    temperature: 0.5,
    enable_thinking: true,
    tools: [tool('web_search')],
  }) as unknown as ApiCompletionParams;

describe('applyRequestSeam', () => {
  beforeEach(() => {
    clearRequestProviders();
    (modelStore as {context?: unknown}).context = undefined;
  });
  afterAll(() => clearRequestProviders());

  it('touches nothing when no provider is registered (upstream behaviour)', async () => {
    const params = makeParams();
    const snapshot = JSON.stringify(params);
    const messages = params.messages;
    const tools = params.tools;
    const allowed = ['web_search'];
    await applyRequestSeam(params, allowed, {spoken: false});
    expect(JSON.stringify(params)).toBe(snapshot);
    expect(params.messages).toBe(messages);
    expect(params.tools).toBe(tools);
    expect(allowed).toEqual(['web_search']);
  });

  it('writes messages, tools and params back and allows contributed tools', async () => {
    let seen: RequestContext | undefined;
    registerRequestProvider({
      id: 'p',
      contribute: context => {
        seen = context;
        return {
          systemBlocks: [{id: 'base', slot: 'stable', text: 'Base.'}],
          tools: [tool('calculator')],
          params: {temperature: 0.2},
        };
      },
    });
    setSeamEnvironment({
      deviceClass: () => 'C',
      countryCode: () => 'AT',
      studyMode: () => true,
    });
    const params = makeParams();
    const allowed = ['web_search'];
    await applyRequestSeam(params, allowed, {spoken: false});
    expect((params.messages as Array<{content: string}>)[0].content).toBe(
      'Base.\n\nPal prompt.',
    );
    expect(params.temperature).toBe(0.2);
    expect(
      (params.tools as ToolDefinition[]).map(t => t.function.name),
    ).toEqual(['web_search', 'calculator']);
    expect(allowed).toEqual(['web_search', 'calculator']);
    expect(seen?.session).toMatchObject({
      id: chatSessionStore.activeSessionId,
      thinking: true,
      studyMode: true,
      countryCode: 'AT',
      spoken: false,
    });
    expect(seen?.runtime.deviceClass).toBe('C');
    expect(getLastSentRequest()?.messages).toBe(params.messages);
  });

  it('never lets a spoken reply think', async () => {
    let thinking: boolean | undefined;
    registerRequestProvider({
      id: 'p',
      contribute: context => {
        thinking = context.session.thinking;
      },
    });
    await applyRequestSeam(makeParams(), [], {spoken: true});
    expect(thinking).toBe(false);
  });

  it('sends the request as upstream built it when the pipeline fails', async () => {
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {});
    registerRequestProvider({id: 'p', contribute: () => ({})});
    const params = makeParams();
    const snapshot = JSON.stringify(params);
    const original = Object.getOwnPropertyDescriptor(
      chatSessionStore,
      'activeSessionId',
    );
    Object.defineProperty(chatSessionStore, 'activeSessionId', {
      configurable: true,
      get: () => {
        throw new Error('store down');
      },
    });
    await expect(applyRequestSeam(params, [])).resolves.toBeUndefined();
    Object.defineProperty(
      chatSessionStore,
      'activeSessionId',
      original ?? {value: 'session-1', writable: true, configurable: true},
    );
    expect(JSON.stringify(params)).toBe(snapshot);
    expect(warn).toHaveBeenCalled();
    warn.mockRestore();
  });

  it('does not rewrite a request that was aborted meanwhile', async () => {
    registerRequestProvider({
      id: 'p',
      contribute: () => ({
        systemBlocks: [{id: 'b', slot: 'stable', text: 'B'}],
      }),
    });
    const controller = new AbortController();
    controller.abort();
    const params = makeParams();
    const snapshot = JSON.stringify(params);
    await applyRequestSeam(params, [], {signal: controller.signal});
    expect(JSON.stringify(params)).toBe(snapshot);
  });
});

describe('resolveSeamRuntime', () => {
  it('uses the loaded context for exact counts and its window', async () => {
    const context = {
      tokenize: jest.fn(async (text: string) => ({
        tokens: text.split(' ').map((_, i) => i),
      })),
      getFormattedChat: jest.fn(async (messages: Array<{content: string}>) => ({
        prompt: messages.map(m => m.content).join(' '),
      })),
    };
    (modelStore as {context?: unknown}).context = context;
    (modelStore as {activeContextSettings?: unknown}).activeContextSettings = {
      n_ctx: 8192,
    };
    const runtime = resolveSeamRuntime();
    expect(runtime.nCtx).toBe(8192);
    expect(runtime.tokenCounter.exact).toBe(true);
    expect(await runtime.tokenCounter.countText('one two three')).toBe(3);
    expect(
      await runtime.tokenCounter.countPrompt([
        {role: 'user', content: 'a b'},
        {role: 'assistant', content: 'c'},
      ]),
    ).toBe(3);
    expect(resolveSeamRuntime().tokenCounter).toBe(runtime.tokenCounter);
    (modelStore as {context?: unknown}).context = undefined;
    (modelStore as {activeContextSettings?: unknown}).activeContextSettings =
      undefined;
  });

  it('falls back to estimates without a local context', () => {
    const runtime = resolveSeamRuntime();
    expect(runtime.tokenCounter.exact).toBe(false);
    expect(runtime.nCtx).toBeGreaterThanOrEqual(4096);
  });
});
