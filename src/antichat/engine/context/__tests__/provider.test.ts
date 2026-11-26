import {
  clearRequestProviders,
  prepareRequest,
  registerRequestProvider,
} from '../../prompt/registry';
import type {ChatMessage} from '../../prompt/types';
import {budgetFor} from '../budget';
import {subscribeContextEvents, type ContextEvent} from '../events';
import {cleanHistory, createContextProvider} from '../provider';
import {
  createMemoryContextStateStore,
  getContextStateStore,
  setContextStateStore,
} from '../summaryStore';
import {createEstimatingCounter} from '../tokenCounter';
import {createFakeEngine, filler} from './support/fakeEngine';

const counter = createEstimatingCounter();

const longChat = (turns: number): ChatMessage[] => {
  const out: ChatMessage[] = [{role: 'system', content: 'You are AntiChat.'}];
  for (let i = 0; i < turns; i++) {
    out.push({
      role: 'user',
      content:
        i === 1 ? 'Note: my dog is called Biscuit.' : `Q${i} ${filler(i, 15)}`,
    });
    out.push({role: 'assistant', content: filler(i + 300, 70)});
  }
  out.push({role: 'user', content: 'And now?'});
  return out;
};

describe('context provider', () => {
  beforeEach(() => {
    clearRequestProviders();
    setContextStateStore(createMemoryContextStateStore());
  });
  afterAll(() => clearRequestProviders());

  const run = (
    messages: ChatMessage[],
    extra: Record<string, unknown> = {},
    session = {},
  ) =>
    prepareRequest({
      messages,
      session: {id: 'chat-1', ...session},
      runtime: {nCtx: 4096, family: 'lfm3', tokenCounter: counter, ...extra},
    });

  it('fits a long chat, writes a summary with the model and stores the state', async () => {
    registerRequestProvider(createContextProvider());
    const engine = createFakeEngine();
    const events: ContextEvent[] = [];
    const stop = subscribeContextEvents(event => events.push(event));
    const result = await run(longChat(40), {engine});
    stop();

    const budget = budgetFor(4096);
    expect(await counter.countPrompt(result.messages)).toBeLessThanOrEqual(
      budget.promptLimit,
    );
    expect(result.messages[0].content).toContain('my dog is called Biscuit');
    expect(result.meta.context).toMatchObject({
      sessionId: 'chat-1',
      nCtx: 4096,
      compacted: true,
      summarized: true,
      offerNewChat: false,
      exact: false,
    });
    expect((result.meta.contextInput as ChatMessage[]).length).toBe(82);
    expect(events.map(e => e.type)).toEqual([
      'compacting',
      'compacting',
      'usage',
    ]);
    expect(events[0]).toEqual({
      type: 'compacting',
      sessionId: 'chat-1',
      active: true,
    });
    expect(engine.calls.every(call => call.kind === 'summary')).toBe(true);
    expect((await getContextStateStore().get('chat-1'))?.compactions).toBe(1);
    const summaryCalls = engine.calls.length;

    // Next turn: the stored state is reused, no new summary is written.
    const next = await run(
      [
        ...longChat(40),
        {role: 'assistant', content: 'ok'},
        {role: 'user', content: 'More?'},
      ],
      {engine},
    );
    expect(next.meta.context).toMatchObject({
      compacted: false,
      summarized: false,
    });
    expect(engine.calls).toHaveLength(summaryCalls);
  });

  it('slides the window without an engine or when summaries are switched off', async () => {
    registerRequestProvider(createContextProvider({summarize: false}));
    const engine = createFakeEngine();
    const result = await run(longChat(40), {engine});
    expect(engine.calls).toHaveLength(0);
    expect(result.meta.context).toMatchObject({
      compacted: true,
      summarized: false,
    });
    expect(result.messages[0].content).toBe('You are AntiChat.');
  });

  it('keeps temporary chats out of the shared store', async () => {
    registerRequestProvider(createContextProvider());
    await run(
      longChat(40),
      {engine: createFakeEngine()},
      {id: 'temp-1', temporary: true},
    );
    expect(await getContextStateStore().get('temp-1')).toBeNull();
  });

  it('leaves a short chat alone apart from cleaning leaked markup in history', async () => {
    registerRequestProvider(createContextProvider());
    const messages: ChatMessage[] = [
      {role: 'user', content: 'Capital of France?'},
      {role: 'assistant', content: '<think>easy</think>Paris.<|im_end|>'},
      {role: 'user', content: 'And Spain? Write <think> literally.'},
    ];
    const result = await run(messages);
    expect(result.messages[1].content).toBe('Paris.');
    expect(result.messages[2]).toBe(messages[2]);
    expect(cleanHistory(messages)[0]).toBe(messages[0]);
  });

  it('cuts oversized tool results and pastes at insertion', async () => {
    registerRequestProvider(createContextProvider());
    const budget = budgetFor(4096);
    const result = await run([
      {role: 'user', content: 'Search it'},
      {role: 'assistant', content: '', tool_calls: [{id: 'c1'}]},
      {role: 'tool', tool_call_id: 'c1', content: filler(1, 3000)},
      {role: 'assistant', content: 'Found it.'},
      {role: 'user', content: `Summarise: ${filler(2, 2500)}`},
    ]);
    expect(
      await counter.countText(result.messages[2].content as string),
    ).toBeLessThanOrEqual(budget.toolResultTokens);
    expect(
      await counter.countText(result.messages[4].content as string),
    ).toBeLessThanOrEqual(budget.attachmentTokens);
    expect(await counter.countPrompt(result.messages)).toBeLessThanOrEqual(
      budget.promptLimit,
    );
  });
});
