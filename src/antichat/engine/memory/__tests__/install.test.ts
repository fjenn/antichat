import {talentRegistry} from '../../../../services/talents/TalentRegistry';
import {chatSessionStore, modelStore} from '../../../../store';
import {
  clearRequestProviders,
  listRequestProviders,
} from '../../prompt/registry';
import {applyRequestSeam, getLastSentRequest} from '../../prompt/seam';
import type {ChatMessage} from '../../prompt/types';
import {
  getMemoryEngine,
  handleReply,
  installMemoryEngine,
  registerMemorySchemas,
  uninstallMemoryEngine,
} from '../install';
import type {MemoryRequestMeta} from '../types';
import {createChatHarness, type ChatHarness} from './support/memoryHarness';
import {createScriptedEngine} from './support/scriptedEngine';

jest.mock('@react-native-async-storage/async-storage', () => ({
  getItem: jest.fn().mockResolvedValue(null),
  setItem: jest.fn().mockResolvedValue(undefined),
  removeItem: jest.fn().mockResolvedValue(undefined),
}));

describe('installMemoryEngine (bound to the app stores)', () => {
  let h: ChatHarness;

  beforeEach(async () => {
    registerMemorySchemas();
    h = await createChatHarness();
    clearRequestProviders();
  });
  afterEach(() => {
    uninstallMemoryEngine();
    clearRequestProviders();
    h.close();
  });

  const send = async (text: string) => {
    const params = {messages: [{role: 'user', content: text}]} as never as {
      messages: ChatMessage[];
      tools?: Array<{function: {name: string}}>;
    };
    const allowed: string[] = [];
    await applyRequestSeam(params as never, allowed);
    return {params, allowed};
  };

  it('registers providers and tools, and removes the providers again', async () => {
    expect(getMemoryEngine()).toBeNull();
    const engine = await installMemoryEngine({
      db: h.db,
      chats: h.chats.store,
      idleMs: 3_600_000,
    });
    expect(getMemoryEngine()).toBe(engine);
    // A second call hands back the same engine.
    expect(await installMemoryEngine({db: h.db})).toBe(engine);
    expect(listRequestProviders().map(provider => provider.id)).toEqual([
      'antichat.project',
      'antichat.memory',
    ]);
    for (const name of ['save_memory', 'forget_memory', 'search_chats']) {
      expect(talentRegistry.get(name)).toBeDefined();
    }
    uninstallMemoryEngine();
    expect(listRequestProviders()).toEqual([]);
    expect(getMemoryEngine()).toBeNull();
  });

  it('sends memories through the seam and allows the memory tools', async () => {
    const engine = await installMemoryEngine({db: h.db, idleMs: 3_600_000});
    await engine.store.add({
      text: 'User is vegetarian',
      origin: 'tool',
      kind: 'profile',
    });
    const {params, allowed} = await send('Give me a dinner idea');
    expect(params.messages[0].role).toBe('system');
    expect(String(params.messages[0].content)).toContain(
      '- User is vegetarian',
    );
    expect(allowed).toEqual(
      expect.arrayContaining(['save_memory', 'forget_memory']),
    );
    expect(params.tools!.map(tool => tool.function.name)).toEqual(
      expect.arrayContaining(['save_memory', 'forget_memory']),
    );
  });

  it('after a reply, ties the memory sources to the assistant message', async () => {
    const engine = await installMemoryEngine({db: h.db, idleMs: 3_600_000});
    const memory = await engine.store.add({
      text: 'User is vegetarian',
      origin: 'tool',
      kind: 'profile',
    });
    const sessionId = chatSessionStore.activeSessionId as string;
    const session = chatSessionStore.sessions.find(s => s.id === sessionId)!;
    const original = session.messages;
    // No request has gone through the seam for this chat: nothing to do.
    expect(await handleReply(engine)).toBe(false);

    await send('Give me a dinner idea');
    const meta = getLastSentRequest()!.prepared.meta
      .memory as MemoryRequestMeta;
    expect(meta.useId).toBeDefined();
    session.messages = [
      ...original,
      {
        id: 'assistant-42',
        type: 'assistant_turn',
        author: {id: 'assistant'},
        steps: [{content: 'How about a vegetarian chickpea curry?'}],
      },
    ] as never;
    expect(await handleReply(engine)).toBe(false);
    const use = await engine.port.useForMessage('assistant-42');
    expect(use!.items).toEqual([
      expect.objectContaining({memoryId: memory!.id, cited: true}),
    ]);
    session.messages = original;
  });

  it('captures "remember that …" when the model did not call the tool', async () => {
    const model = createScriptedEngine(
      () =>
        '{"memories": [{"text": "User has two cats.", "type": "profile", "private": false}]}',
    );
    const end = jest.fn();
    const engine = await installMemoryEngine({db: h.db, idleMs: 3_600_000});
    const sessionId = chatSessionStore.activeSessionId as string;
    const session = chatSessionStore.sessions.find(s => s.id === sessionId)!;
    const original = session.messages;
    await send('Please remember that I have two cats.');
    session.messages = [
      ...original,
      {
        id: 'assistant-43',
        type: 'assistant_turn',
        author: {id: 'assistant'},
        steps: [{content: 'I will keep that in mind.'}],
      },
    ] as never;

    // The model is busy with the title: ask to be called again.
    (modelStore.tryAcquireGeneration as jest.Mock).mockReturnValue(null);
    expect(await handleReply(engine)).toBe(true);
    expect(await engine.store.count()).toBe(0);

    (modelStore.tryAcquireGeneration as jest.Mock).mockReturnValue({
      engine: model,
      signal: new AbortController().signal,
      abort: jest.fn(),
      end,
    });
    expect(await handleReply(engine, 1)).toBe(false);
    expect((await engine.store.list()).map(m => m.text)).toEqual([
      'User has two cats.',
    ]);
    expect(end).toHaveBeenCalledTimes(1);

    // When the model did call save_memory, nothing is captured twice.
    session.messages = [
      ...original,
      {
        id: 'assistant-44',
        type: 'assistant_turn',
        author: {id: 'assistant'},
        steps: [
          {
            toolCalls: [
              {id: 'c1', function: {name: 'save_memory', arguments: '{}'}},
            ],
          },
          {content: 'Saved.'},
        ],
      },
    ] as never;
    model.calls.length = 0;
    expect(await handleReply(engine)).toBe(false);
    expect(model.calls).toHaveLength(0);
    session.messages = original;
  });
});
