/**
 * Prefix stability: the KV / prefix cache is only reused while each request
 * starts with the bytes of the previous one. These tests pin that property
 * and report the cache hit rate "before" (a naive pipeline) and "after".
 *
 * The fake engine emulates llama.cpp's prefix cache (`timings.cache_n`); the
 * real `tokens_cached` numbers are in docs/antichat/m7-prompt-eval.md.
 */
import {
  setPersonalization,
  resetPersonalization,
} from '../../prompt/personalization';
import {createSystemPromptProvider} from '../../prompt/provider';
import {
  clearRequestProviders,
  prepareRequest,
  registerRequestProvider,
} from '../../prompt/registry';
import {buildSystemPrompt, timeLine} from '../../prompt/systemPrompt';
import type {ChatMessage, RequestProvider} from '../../prompt/types';
import {createSkillsProvider} from '../../skills/provider';
import {budgetFor} from '../budget';
import {createContextProvider} from '../provider';
import {
  createMemoryContextStateStore,
  setContextStateStore,
} from '../summaryStore';
import {createEstimatingCounter, messageText} from '../tokenCounter';
import {createFakeEngine} from './support/fakeEngine';
import {runScriptedChat, userMessage} from './support/scriptedChat';

jest.mock('@react-native-async-storage/async-storage', () => ({
  __esModule: true,
  default: {
    getItem: jest.fn(async () => null),
    setItem: jest.fn(async () => {}),
    removeItem: jest.fn(async () => {}),
  },
}));

const counter = createEstimatingCounter();
const flat = (messages: ChatMessage[]) =>
  messages.map(m => `<${m.role}>${messageText(m).text}`).join('\n');

/**
 * What a first attempt usually looks like: the clock in the system prompt,
 * volatile blocks first, and a window that slides a little on every turn.
 */
function naiveProviders(clock: () => Date): RequestProvider[] {
  return [
    {
      id: 'naive.system',
      contribute: () => ({
        systemBlocks: [
          {id: 'time', slot: 'stable', order: 1, text: timeLine(clock())},
          {
            id: 'base',
            slot: 'stable',
            order: 2,
            text: buildSystemPrompt({now: clock()}),
          },
        ],
      }),
    },
    {
      id: 'naive.window',
      order: 900,
      transform: async (draft, context) => {
        const limit = budgetFor(context.runtime.nCtx).promptLimit;
        const [system, ...history] = draft.messages;
        let kept = history;
        while (
          kept.length > 1 &&
          (await counter.countPrompt([system, ...kept])) > limit
        ) {
          kept = kept.slice(2);
        }
        return {...draft, messages: [system, ...kept]};
      },
    },
  ];
}

describe('prefix stability', () => {
  beforeEach(() => {
    clearRequestProviders();
    resetPersonalization();
    setContextStateStore(createMemoryContextStateStore());
  });
  afterAll(() => {
    clearRequestProviders();
    resetPersonalization();
  });

  const install = () => {
    registerRequestProvider(createSystemPromptProvider());
    registerRequestProvider(createSkillsProvider());
    registerRequestProvider(createContextProvider());
  };

  const send = (history: ChatMessage[], now: Date, session = {}) =>
    prepareRequest({
      messages: [...history],
      session: {id: 's', ...session},
      runtime: {nCtx: 8192, family: 'gemma4', tokenCounter: counter, now},
    });

  it('each request starts with the whole previous request, minute after minute', async () => {
    install();
    const history: ChatMessage[] = [];
    let previous = '';
    for (let turn = 0; turn < 12; turn++) {
      history.push({role: 'user', content: `Tell me about topic ${turn}.`});
      // Seven minutes pass between turns; one turn crosses the hour.
      const now = new Date(2026, 10, 24, 14, 5 + turn * 7);
      const prepared = await send(history, now);
      const prompt = flat(prepared.messages);
      const withoutNewest = flat(prepared.messages.slice(0, -1));
      expect(withoutNewest.startsWith(previous)).toBe(true);
      history.push({role: 'assistant', content: `Reply ${turn}.`});
      previous = `${prompt}\n<assistant>Reply ${turn}.`;
    }
  });

  it('the system message is byte-identical across turns of a chat', async () => {
    install();
    setPersonalization(
      {
        preset: 'friendly',
        nickname: 'Marisol',
        customInstructions: 'Be brief.',
      },
      false,
    );
    const systems = new Set<string>();
    const history: ChatMessage[] = [];
    for (let turn = 0; turn < 6; turn++) {
      history.push({
        role: 'user',
        content: turn === 3 ? 'What time is it?' : `Question ${turn}`,
      });
      const prepared = await send(
        history,
        new Date(2026, 10, 24, 9 + turn, turn * 9),
      );
      systems.add(prepared.messages[0].content as string);
      if (turn === 3) {
        // The clock rides on the newest user turn, not in the system prompt.
        expect(prepared.messages[prepared.messages.length - 1].content).toBe(
          'What time is it?\n\n[Current local time: 12:27.]',
        );
      }
      history.push({role: 'assistant', content: 'ok'});
    }
    expect(systems.size).toBe(1);
  });

  it('volatile blocks from other providers sit after every stable block', async () => {
    install();
    registerRequestProvider({
      id: 'memory',
      order: 50,
      contribute: () => ({
        systemBlocks: [
          {
            id: 'memory',
            slot: 'session',
            order: 50,
            text: 'What you know about the user:\n- Likes tea',
          },
        ],
      }),
    });
    setPersonalization({customInstructions: 'Be brief.'}, false);
    const prepared = await send(
      [{role: 'user', content: 'Hi'}],
      new Date(2026, 10, 24, 9, 0),
    );
    const system = prepared.messages[0].content as string;
    const order = [
      'You are AntiChat',
      'Be brief.',
      'Current date:',
      'Likes tea',
    ].map(marker => system.indexOf(marker));
    expect(order.every(index => index >= 0)).toBe(true);
    expect([...order].sort((a, b) => a - b)).toEqual(order);
  });

  it('only the day changes the prefix, and only its tail', async () => {
    install();
    const history = [{role: 'user', content: 'Hi'}];
    const today = (await send(history, new Date(2026, 10, 24, 23, 58)))
      .messages[0].content as string;
    const sameDay = (await send(history, new Date(2026, 10, 24, 0, 1)))
      .messages[0].content as string;
    const tomorrow = (await send(history, new Date(2026, 10, 25, 0, 1)))
      .messages[0].content as string;
    expect(sameDay).toBe(today);
    const shared = today.slice(0, today.indexOf('Current date:'));
    expect(tomorrow.startsWith(shared)).toBe(true);
    expect(shared.length / today.length).toBeGreaterThan(0.9);
  });

  it('reports the cache hit rate before and after, short and long chats', async () => {
    const rows: string[] = [];
    for (const turns of [20, 200]) {
      let minute = 0;
      // Baseline 1: clock in the system prompt, window slides every turn.
      const naive = await runScriptedChat({
        family: 'gemma4',
        nCtx: 4096,
        counter,
        turns,
        providers: naiveProviders(
          () => new Date(2026, 10, 24, 9, minute++ * 2),
        ),
      });
      // Baseline 2: our stable system prompt, but a window that slides a
      // little on every turn instead of compacting in steps.
      const sliding = await runScriptedChat({
        family: 'gemma4',
        nCtx: 4096,
        counter,
        turns,
        providers: [
          createSystemPromptProvider({personalization: () => null}),
          createSkillsProvider(),
          naiveProviders(() => new Date())[1],
        ],
      });
      const after = await runScriptedChat({
        family: 'gemma4',
        nCtx: 4096,
        counter,
        turns,
      });
      const pct = (value: number) => `${(value * 100).toFixed(1)}%`;
      rows.push(
        `${turns} turns at 4k: clock-in-prompt ${pct(naive.cacheHitRate)} | sliding window ${pct(sliding.cacheHitRate)} | stepwise (ours) ${pct(after.cacheHitRate)}`,
      );
      expect(after.cacheHitRate).toBeGreaterThan(naive.cacheHitRate + 0.5);
      expect(after.cacheHitRate).toBeGreaterThan(sliding.cacheHitRate);
      expect(after.cacheHitRate).toBeGreaterThan(0.85);
      expect(after.maxPromptTokens).toBeLessThanOrEqual(after.promptLimit);
    }

    console.info(
      `prefix-cache hit rate (emulated tokens_cached)\n${rows.join('\n')}`,
    );
  }, 120000);

  it('the scripted chat script itself is deterministic', () => {
    expect(userMessage(7, 200)).toBe(userMessage(7, 200));
    expect(userMessage(199, 200)).toBe('What is my dog called?');
    const engine = createFakeEngine();
    expect(engine.cacheHitRate()).toBe(0);
  });
});
