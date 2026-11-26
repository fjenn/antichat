import {chatSessionStore, modelStore} from '../../../../store';
import {
  createFakeEngine,
  filler,
} from '../../context/__tests__/support/fakeEngine';
import {budgetFor} from '../../context/budget';
import {
  createMemoryContextStateStore,
  getContextStateStore,
  setContextStateStore,
} from '../../context/summaryStore';
import {createEstimatingCounter} from '../../context/tokenCounter';
import {installPromptEngine} from '../install';
import {
  installPostTurnHooks,
  isAutomaticTitle,
  runAfterReply,
  runPostTurn,
  subscribeFollowUps,
} from '../postTurn';
import {
  clearRequestProviders,
  hasRequestProviders,
  listRequestProviders,
} from '../registry';
import {applyRequestSeam, setSeamEnvironment} from '../seam';
import {TITLE_INLINE_INSTRUCTION, TITLE_SYSTEM_PROMPT} from '../title';
import type {ChatMessage, RuntimeInfo} from '../types';

jest.mock('@react-native-async-storage/async-storage', () => ({
  __esModule: true,
  default: {
    getItem: jest.fn(async () => null),
    setItem: jest.fn(async () => {}),
    removeItem: jest.fn(async () => {}),
  },
}));

const runtime = (
  overrides: Partial<RuntimeInfo> = {},
): Omit<RuntimeInfo, 'engine'> => ({
  nCtx: 4096,
  family: 'gemma4',
  deviceClass: 'C',
  tokenCounter: createEstimatingCounter(),
  now: new Date(2026, 10, 24, 14, 5),
  ...overrides,
});

const first: ChatMessage[] = [
  {role: 'system', content: 'You are AntiChat.'},
  {
    role: 'user',
    content: 'Plan a 3 day trip to Lisbon in March for two people.',
  },
];

describe('runPostTurn', () => {
  beforeEach(() => setContextStateStore(createMemoryContextStateStore()));

  it('titles the first exchange inline for Gemma and suggests follow-ups on class C', async () => {
    const engine = createFakeEngine();
    engine.titleFor = () => 'Lisbon Trip Plan';
    const result = await runPostTurn({
      engine,
      runtime: runtime(),
      sessionId: 's',
      messages: first,
      reply: 'Day 1: Alfama.<|im_end|>',
    });
    expect(result).toEqual({
      title: 'Lisbon Trip Plan',
      titleGenerated: true,
      followUps: [
        'Can you give an example?',
        'What should I avoid?',
        'How long does it take?',
      ],
      compacted: false,
    });
    const [title, followUps] = engine.calls;
    expect(title.messages.slice(0, 2)).toEqual(first);
    expect(title.messages[2]).toEqual({
      role: 'assistant',
      content: 'Day 1: Alfama.',
    });
    expect(title.messages[3].content).toBe(TITLE_INLINE_INSTRUCTION);
    expect(followUps.kind).toBe('followups');
  });

  it('uses the stand-alone title prompt where inline titles drift (Qwen3.5)', async () => {
    const engine = createFakeEngine();
    await runPostTurn({
      engine,
      runtime: runtime({family: 'qwen35'}),
      messages: first,
      reply: 'Sure.',
    });
    expect(engine.calls[0].messages[0].content).toBe(TITLE_SYSTEM_PROMPT);
  });

  it('titles only the first exchange and skips follow-ups on small devices', async () => {
    const engine = createFakeEngine();
    const result = await runPostTurn({
      engine,
      runtime: runtime({deviceClass: 'A'}),
      messages: [
        ...first,
        {role: 'assistant', content: 'Plan.'},
        {role: 'user', content: 'And day two in detail please?'},
      ],
      reply: 'Belém.',
    });
    expect(result).toEqual({followUps: [], compacted: false});
    expect(engine.calls).toHaveLength(0);
  });

  it('does nothing without a reply, and stops when aborted', async () => {
    const engine = createFakeEngine();
    expect(
      await runPostTurn({
        engine,
        runtime: runtime(),
        messages: first,
        reply: '  ',
      }),
    ).toEqual({
      followUps: [],
      compacted: false,
    });
    const controller = new AbortController();
    controller.abort();
    const aborted = await runPostTurn({
      engine,
      runtime: runtime(),
      messages: first,
      reply: 'x',
      signal: controller.signal,
    });
    expect(aborted.followUps).toEqual([]);
    expect(engine.calls).toHaveLength(0);
  });

  it('compacts early, at the soft trigger, so the next send does not wait', async () => {
    const engine = createFakeEngine();
    const counter = createEstimatingCounter();
    const budget = budgetFor(4096);
    const history: ChatMessage[] = [
      {role: 'system', content: 'You are AntiChat.'},
    ];
    let i = 0;
    while ((await counter.countPrompt(history)) < budget.softTriggerTokens) {
      history.push({role: 'user', content: `Q${i} ${filler(i, 12)}`});
      history.push({role: 'assistant', content: filler(i++ + 50, 70)});
    }
    history.push({role: 'user', content: 'Last one?'});
    expect(await counter.countPrompt(history)).toBeLessThan(
      budget.triggerTokens,
    );
    const result = await runPostTurn({
      engine,
      runtime: runtime({deviceClass: 'A', tokenCounter: counter}),
      sessionId: 'early',
      messages: history,
      reply: 'Done.',
      title: false,
    });
    expect(result.compacted).toBe(true);
    expect(engine.calls.map(c => c.kind)).toEqual(['summary']);
    const state = await getContextStateStore().get('early');
    expect(state?.cutCount).toBeGreaterThan(0);
    expect(state?.summarizedCount).toBe(state?.cutCount);
  });
});

describe('install and store hooks', () => {
  afterEach(() => clearRequestProviders());

  it('registers the three providers and removes them again', () => {
    expect(hasRequestProviders()).toBe(false);
    const remove = installPromptEngine({
      postTurn: false,
      persistSummaries: false,
      environment: {deviceClass: () => 'D'},
    });
    expect(listRequestProviders().map(p => p.id)).toEqual([
      'antichat.system-prompt',
      'antichat.skills',
      'antichat.context',
    ]);
    remove();
    expect(hasRequestProviders()).toBe(false);
  });

  it('with the engine installed, a send through the seam gets the AntiChat prompt', async () => {
    const remove = installPromptEngine({
      postTurn: false,
      persistSummaries: false,
    });
    const params = {
      messages: [{role: 'user', content: 'Hi there'}],
    } as never as {messages: ChatMessage[]; enable_thinking?: boolean};
    await applyRequestSeam(params as never, []);
    expect(params.messages[0].role).toBe('system');
    expect(params.messages[0].content as string).toContain('You are AntiChat');
    expect(params.enable_thinking).toBe(false);
    remove();
  });

  it('after a reply, titles the chat through the generation lease', async () => {
    const engine = createFakeEngine();
    engine.titleFor = () => 'Friendly First Chat';
    const end = jest.fn();
    (modelStore.tryAcquireGeneration as jest.Mock).mockReturnValue({
      engine,
      signal: new AbortController().signal,
      abort: jest.fn(),
      end,
    });
    const remove = installPromptEngine({
      persistSummaries: false,
      postTurn: false,
    });
    const sessionId = chatSessionStore.activeSessionId as string;
    const session = chatSessionStore.sessions.find(s => s.id === sessionId)!;
    const original = session.messages;
    const originalTitle = session.title;
    session.title = 'Tell me something nice about today';
    const seen: string[][] = [];
    const stop = subscribeFollowUps((_id, items) => seen.push(items));

    // Nothing went through the seam yet for this chat: nothing happens.
    await runAfterReply();
    expect(end).not.toHaveBeenCalled();

    await applyRequestSeam(
      {
        messages: [
          {role: 'user', content: 'Tell me something nice about today'},
        ],
      } as never,
      [],
    );
    session.messages = [
      ...original,
      {
        id: 'u',
        type: 'text',
        text: 'Tell me something nice about today',
        author: {id: 'user'},
      },
      {
        id: 'a',
        type: 'assistant_turn',
        author: {id: 'assistant'},
        steps: [{content: 'Today is a fine day.'}],
      },
    ] as never;
    setSeamEnvironment({deviceClass: () => 'C'});
    await runAfterReply({compact: false});

    expect(chatSessionStore.updateSessionTitleBySessionId).toHaveBeenCalledWith(
      sessionId,
      'Friendly First Chat',
    );
    expect(end).toHaveBeenCalledTimes(1);
    expect(seen).toEqual([
      [
        'Can you give an example?',
        'What should I avoid?',
        'How long does it take?',
      ],
    ]);
    stop();
    remove();
    // A title the user typed is never overwritten.
    (chatSessionStore.updateSessionTitleBySessionId as jest.Mock).mockClear();
    session.title = 'My own name for it';
    await runAfterReply({compact: false, followUps: false});
    expect(
      chatSessionStore.updateSessionTitleBySessionId,
    ).not.toHaveBeenCalled();
    expect(isAutomaticTitle('New Session', 'x')).toBe(true);
    expect(
      isAutomaticTitle(
        'How do I get red wine out of a white car...',
        'How do I get red wine out of a white carpet?',
      ),
    ).toBe(true);

    session.messages = original;
    session.title = originalTitle;
    setSeamEnvironment({deviceClass: () => 'B'});
  });

  it('gives the engine back as soon as the user sends again', async () => {
    const controller = new AbortController();
    const engine = createFakeEngine();
    let release: (() => void) | undefined;
    engine.completion = jest.fn(
      () =>
        new Promise(resolve => {
          release = () => resolve({text: '', content: ''});
        }),
    ) as never;
    engine.stopCompletion = jest.fn(async () => release?.());
    const lease = {
      engine,
      signal: controller.signal,
      abort: jest.fn(() => controller.abort()),
      end: jest.fn(),
    };
    (modelStore.tryAcquireGeneration as jest.Mock).mockReturnValue(lease);
    (chatSessionStore.updateSessionTitleBySessionId as jest.Mock).mockClear();
    const sessionId = chatSessionStore.activeSessionId as string;
    const session = chatSessionStore.sessions.find(s => s.id === sessionId)!;
    const original = session.messages;
    await applyRequestSeam(
      {
        messages: [{role: 'user', content: 'Explain how tides work please'}],
      } as never,
      [],
    );
    session.messages = [
      ...original,
      {
        id: 'a',
        type: 'assistant_turn',
        author: {id: 'assistant'},
        steps: [{content: 'The moon pulls.'}],
      },
    ] as never;
    const job = runAfterReply({compact: false, followUps: false});
    await new Promise(resolve => setTimeout(resolve, 30));
    (chatSessionStore as {isStopping: boolean}).isStopping = true;
    await job;
    (chatSessionStore as {isStopping: boolean}).isStopping = false;
    expect(lease.abort).toHaveBeenCalled();
    expect(engine.stopCompletion).toHaveBeenCalled();
    expect(lease.end).toHaveBeenCalledTimes(1);
    expect(
      chatSessionStore.updateSessionTitleBySessionId,
    ).not.toHaveBeenCalled();
    session.messages = original;
  });

  it('stays out of the way when the lease is busy, and the watcher can be removed', async () => {
    (modelStore.tryAcquireGeneration as jest.Mock).mockReturnValue(null);
    (chatSessionStore.updateSessionTitleBySessionId as jest.Mock).mockClear();
    await applyRequestSeam(
      {
        messages: [{role: 'user', content: 'Hello there, how are you'}],
      } as never,
      [],
    );
    await runAfterReply();
    expect(
      chatSessionStore.updateSessionTitleBySessionId,
    ).not.toHaveBeenCalled();
    const stop = installPostTurnHooks({idleDelayMs: 1});
    expect(() => stop()).not.toThrow();
  });
});
