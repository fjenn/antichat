import {messageText} from '../../context/tokenCounter';
import {createSystemPromptProvider} from '../../prompt/provider';
import {
  clearRequestProviders,
  registerRequestProvider,
} from '../../prompt/registry';
import type {ChatMessage} from '../../prompt/types';
import {createMemoryEngine, type MemoryEngine} from '../engine';
import type {MemoryEvent, MemoryRequestMeta} from '../types';
import {sendTurn, type TurnOutput} from './support/chatLoop';
import {createChatHarness, type ChatHarness} from './support/memoryHarness';
import {
  createScriptedEngine,
  toolCall,
  type ScriptedEngine,
} from './support/scriptedEngine';

const NOW = new Date(2026, 10, 24, 14, 5);

/**
 * A model that behaves like a good small model would, and can only know
 * what is in its prompt: it mentions "vegetarian" in a dinner idea only
 * when a saved memory in the system message says so.
 */
function createChatModel(): ScriptedEngine {
  return createScriptedEngine(call => {
    const tools = (call.params.tools ?? []).map((t: any) => t.function.name);
    const lastRole = call.messages[call.messages.length - 1].role;
    const users = call.messages.filter(m => m.role === 'user');
    const question = messageText(users[users.length - 1]).text;
    if (call.system.startsWith('You maintain the long-term memory')) {
      const match = /remember that (i[^.]*)/i.exec(question);
      return JSON.stringify({
        memories: match
          ? [
              {
                text: `User ${match[1]
                  .replace(/^i(?:'m| am)\s*/i, 'is ')
                  .replace(/^i\s+/i, '')}.`,
                type: 'profile',
                private: false,
              },
            ]
          : [],
      });
    }
    if (lastRole === 'tool') {
      return 'Done.';
    }
    const remember = /remember that i'm (\w+)/i.exec(question);
    if (remember && tools.includes('save_memory')) {
      return {
        tool_calls: [
          toolCall('save_memory', {fact: `User is ${remember[1]}.`}),
        ],
      };
    }
    const forgetIt = /forget that i'm (\w+)/i.exec(question);
    if (forgetIt && tools.includes('forget_memory')) {
      return {
        tool_calls: [toolCall('forget_memory', {fact: `is ${forgetIt[1]}`})],
      };
    }
    if (/trip/i.test(question) && tools.includes('search_chats')) {
      return {tool_calls: [toolCall('search_chats', {query: 'lisbon trip'})]};
    }
    if (/dinner/i.test(question)) {
      return /vegetarian/i.test(call.system)
        ? 'How about a vegetarian chickpea curry?'
        : 'How about roast chicken with potatoes?';
    }
    return 'Sure.';
  });
}

describe('memory engine, end to end with a scripted model', () => {
  let h: ChatHarness;
  let engine: MemoryEngine;
  let model: ScriptedEngine;
  let current: {id: string | null; userText: string};
  let events: MemoryEvent[];
  let leaseFree: boolean;

  beforeEach(async () => {
    h = await createChatHarness();
    model = createChatModel();
    current = {id: null, userText: ''};
    leaseFree = true;
    engine = createMemoryEngine({
      db: h.db,
      chats: h.chats.store,
      now: () => h.clock.now,
      currentSessionId: () => current.id,
      currentUserText: () => current.userText,
      acquireModel: () =>
        leaseFree ? {engine: model, family: 'gemma4', end: () => {}} : null,
      deviceClass: () => 'C',
      quietMs: 0,
    });
    await engine.init();
    events = [];
    engine.store.subscribe(event => events.push(event));
    clearRequestProviders();
    registerRequestProvider(
      createSystemPromptProvider({personalization: () => null}),
    );
    engine.providers.forEach(provider => registerRequestProvider(provider));
  });
  afterEach(() => {
    clearRequestProviders();
    h.close();
  });

  /** One chat turn as the app runs it, including the after-reply hook. */
  const turn = async (
    sessionId: string,
    userText: string,
    history: ChatMessage[] = [],
    options: {temporary?: boolean; messageId?: string} = {},
  ): Promise<TurnOutput & {cited: string[]}> => {
    current = {id: sessionId, userText};
    const sent = await sendTurn({
      engine: model,
      family: 'gemma4',
      nCtx: 8192,
      history,
      userText,
      session: {id: sessionId, temporary: options.temporary},
      tools: engine.tools,
      now: NOW,
    });
    const outcome = await engine.afterReply({
      sessionId,
      messageId: options.messageId ?? `${sessionId}-reply-${history.length}`,
      userText,
      reply: sent.reply,
      meta: sent.prepared.meta,
      toolsCalled: sent.toolCalls.map(call => call.name),
    });
    return {...sent, cited: outcome.cited};
  };

  const memories = async () =>
    (await engine.store.list()).map(memory => memory.text);

  it('remembers on request, uses it in a new chat, and stops after deletion', async () => {
    // Chat 1: the explicit request goes through the save_memory tool.
    const first = await turn('chat-1', "Remember that I'm vegetarian");
    expect(first.toolCalls).toEqual([
      {
        name: 'save_memory',
        args: '{"fact":"User is vegetarian."}',
        result: expect.stringMatching(/^Saved to memory: User is vegetarian\./),
      },
    ]);
    expect(first.reply).toBe('Done.');
    expect(await memories()).toEqual(['User is vegetarian.']);
    expect(events).toContainEqual(
      expect.objectContaining({type: 'saved', sessionId: 'chat-1'}),
    );

    // Chat 2: a new chat knows it and the answer reports the memory.
    const second = await turn('chat-2', 'Give me a dinner idea', [], {
      messageId: 'msg-dinner',
    });
    expect(second.reply).toBe('How about a vegetarian chickpea curry?');
    const [memory] = await engine.store.list();
    expect(second.cited).toEqual([memory.id]);
    const use = await engine.port.useForMessage('msg-dinner');
    expect(use).toMatchObject({sessionId: 'chat-2', messageId: 'msg-dinner'});
    expect(use!.items).toEqual([
      {
        memoryId: memory.id,
        text: 'User is vegetarian.',
        kind: 'profile',
        how: 'always',
        cited: true,
      },
    ]);
    expect((await engine.store.get(memory.id))!.useCount).toBe(1);

    // The user deletes it in the manage screen: it stops, at once.
    await engine.port.delete([memory.id]);
    const third = await turn(
      'chat-2',
      'Another dinner idea please',
      second.history,
    );
    expect(third.reply).toBe('How about roast chicken with potatoes?');
    expect(String(third.prepared.messages[0].content)).not.toContain(
      'vegetarian',
    );
    expect((third.prepared.meta.memory as MemoryRequestMeta).injected).toEqual(
      [],
    );
    expect(await engine.port.useForMessage('msg-dinner')).toBeNull();
    const fourth = await turn('chat-3', 'Give me a dinner idea');
    expect(fourth.reply).toBe('How about roast chicken with potatoes?');
  });

  it('writes nothing from a temporary chat', async () => {
    const temp = h.chats.up.addSession('Temp');
    await h.chats.store.markTemporary(temp);
    const sent = await turn(temp, "Remember that I'm vegetarian", [], {
      temporary: true,
    });
    // The tools are not even offered, and the fallback capture stays out.
    expect(sent.prepared.tools).toEqual([]);
    expect(sent.toolCalls).toEqual([]);
    h.clock.now += 120_000;
    await engine.leaveChat(temp);
    await engine.idle();
    expect(await memories()).toEqual([]);
    for (const table of [
      'memories',
      'memory_uses',
      'memory_extraction',
      'chat_digests',
    ]) {
      expect(await h.db.all(`SELECT * FROM ${table}`)).toEqual([]);
    }
    const later = await turn('chat-9', 'Give me a dinner idea');
    expect(later.reply).toBe('How about roast chicken with potatoes?');
  });

  it('catches a request the model answered without calling the tool', async () => {
    // "remember that I have …" does not trigger this model's tool call.
    const sent = await turn('chat-1', 'Please remember that I have two cats.');
    expect(sent.toolCalls).toEqual([]);
    expect(await memories()).toEqual(['User have two cats.']);
    expect((await engine.store.list())[0]).toMatchObject({
      origin: 'extraction',
      importance: 0.9,
    });
  });

  it('forgets on request through the tool', async () => {
    await turn('chat-1', "Remember that I'm vegetarian");
    const sent = await turn('chat-1', "Forget that I'm vegetarian");
    expect(sent.toolCalls[0]).toMatchObject({
      name: 'forget_memory',
      result: expect.stringMatching(
        /^Deleted from memory: User is vegetarian\./,
      ),
    });
    expect(await memories()).toEqual([]);
    expect((await turn('chat-2', 'Give me a dinner idea')).reply).toContain(
      'roast chicken',
    );
  });

  it('pauses: reads what is saved, saves nothing new', async () => {
    await turn('chat-1', "Remember that I'm vegetarian");
    await engine.port.setPaused(true);
    const sent = await turn('chat-2', "Remember that I'm Dutch");
    // Paused: the write tools are not offered, so nothing can be called.
    expect(sent.toolCalls.filter(call => call.name === 'save_memory')).toEqual(
      [],
    );
    expect(await memories()).toEqual(['User is vegetarian.']);
    expect((await turn('chat-3', 'Give me a dinner idea')).reply).toContain(
      'vegetarian',
    );
  });

  it('looks up an earlier chat with search_chats', async () => {
    await h.addChat('Trip to Lisbon', [
      ['Plan a 3 day trip to Lisbon in March', 'Day 1: Alfama. Stay in Baixa.'],
    ]);
    const sent = await turn('chat-2', 'Where did we say to stay on that trip?');
    expect(sent.toolCalls[0].name).toBe('search_chats');
    expect(sent.toolCalls[0].result).toContain('"Trip to Lisbon"');
    expect(sent.toolCalls[0].result).toContain('Stay in Baixa');
  });

  it('extracts from a chat when the user leaves it', async () => {
    const chat = await h.addChat('Hello', [
      ['Please remember that I live in Porto.', 'Sure.'],
    ]);
    current = {id: 'other-chat', userText: ''};
    const result = await engine.leaveChat(chat);
    expect(result.chats).toBe(1);
    expect(await memories()).toEqual(['User live in Porto.']);
    // The model is busy: the pass waits for another time.
    const second = await h.addChat('Again', [['I like tea.', 'Ok.']]);
    leaseFree = false;
    expect((await engine.leaveChat(second)).reason).toBe('busy');
  });

  it('lets the user manage memories through the port', async () => {
    await engine.port.ready();
    const added = await engine.port.add('I prefer metric units');
    expect(added.status).toBe('added');
    expect(added.memory).toMatchObject({origin: 'user', importance: 0.9});
    expect((await engine.port.add('I prefer metric units')).status).toBe(
      'duplicate',
    );
    const edited = await engine.port.edit(added.memory!.id, {
      text: 'User prefers imperial units',
    });
    expect(edited!.previousText).toBe('I prefer metric units');
    expect((await engine.port.undoUpdate(added.memory!.id))!.text).toBe(
      'I prefer metric units',
    );
    await engine.port.setPinned(added.memory!.id, true);
    expect((await engine.port.list())[0].pinned).toBe(true);
    expect(await engine.port.count()).toBe(1);
    expect(engine.port.getSettings().enabled).toBe(true);
    await engine.port.updateSettings({includeSensitive: true});
    expect(engine.port.getSettings().includeSensitive).toBe(true);
    expect(await engine.port.deleteAll()).toBe(1);
    expect(await engine.port.list()).toEqual([]);
    expect(await engine.port.usesForSession('chat-1')).toEqual([]);
  });
});
