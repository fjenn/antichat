import {createEstimatingCounter} from '../../context/tokenCounter';
import {createSystemPromptProvider} from '../../prompt/provider';
import {
  clearRequestProviders,
  prepareRequest,
  registerRequestProvider,
} from '../../prompt/registry';
import type {ChatMessage, PreparedRequest} from '../../prompt/types';
import {createChatResolver} from '../chatScope';
import {
  MEMORY_PAUSED_REMINDER,
  MEMORY_TOOL_HINT,
  TEMPORARY_CHAT_NOTE,
  TEMPORARY_CHAT_REMINDER,
  createMemoryProvider,
  type MemoryProviderOptions,
} from '../provider';
import {MEMORY_BLOCK_HEADER, RETRIEVED_PREFIX} from '../retrieval';
import type {MemoryRequestMeta} from '../types';
import {createChatHarness, type ChatHarness} from './support/memoryHarness';

const NOW = new Date(2026, 10, 24, 14, 5);
const system = (prepared: PreparedRequest): string =>
  String(prepared.messages[0].content);
const memoryMeta = (prepared: PreparedRequest) =>
  prepared.meta.memory as MemoryRequestMeta | undefined;
const toolNames = (prepared: PreparedRequest) =>
  prepared.tools.map(tool => tool.function.name);

describe('memory request provider', () => {
  let h: ChatHarness;

  const install = (options: Partial<MemoryProviderOptions> = {}) => {
    clearRequestProviders();
    registerRequestProvider(
      createSystemPromptProvider({personalization: () => null}),
    );
    registerRequestProvider(
      createMemoryProvider({
        store: h.store,
        resolveChat: createChatResolver(h.db),
        digests: h.digests,
        ...options,
      }),
    );
  };

  const send = (
    messages: ChatMessage[],
    session: {id?: string; temporary?: boolean} = {id: 'chat-1'},
    nCtx: number = 8192,
  ) =>
    prepareRequest({
      messages,
      session,
      runtime: {
        nCtx,
        family: 'gemma4',
        now: NOW,
        tokenCounter: createEstimatingCounter(),
      },
    });

  const user = (text: string): ChatMessage => ({role: 'user', content: text});
  const assistant = (text: string): ChatMessage => ({
    role: 'assistant',
    content: text,
  });

  beforeEach(async () => {
    h = await createChatHarness();
    install();
  });
  afterEach(() => {
    clearRequestProviders();
    h.close();
  });

  it('adds nothing but the tools when there is nothing to remember', async () => {
    const prepared = await send([user('hello')]);
    expect(system(prepared)).not.toContain(MEMORY_BLOCK_HEADER);
    expect(memoryMeta(prepared)).toMatchObject({injected: [], tokens: 0});
    expect(memoryMeta(prepared)!.useId).toBeUndefined();
    expect(toolNames(prepared)).toEqual([
      'save_memory',
      'forget_memory',
      'search_chats',
    ]);
  });

  it('puts saved memories at the very end of the system message', async () => {
    await h.store.add({
      text: 'User is vegetarian',
      origin: 'tool',
      kind: 'profile',
    });
    await h.store.add({
      text: 'User lives in Lyon',
      origin: 'tool',
      kind: 'profile',
    });
    const prepared = await send([user('Give me a dinner idea')]);
    const text = system(prepared);
    expect(
      text.endsWith(
        `${MEMORY_BLOCK_HEADER}\n- User is vegetarian\n- User lives in Lyon`,
      ),
    ).toBe(true);
    // Stable blocks first, then the date, then memory.
    expect(text.indexOf('You are AntiChat')).toBe(0);
    expect(text.indexOf(MEMORY_TOOL_HINT)).toBeGreaterThan(0);
    expect(text.indexOf(MEMORY_TOOL_HINT)).toBeLessThan(
      text.indexOf('Current date:'),
    );
    expect(text.indexOf('Current date:')).toBeLessThan(
      text.indexOf(MEMORY_BLOCK_HEADER),
    );
    // The user message is untouched: nothing was retrieved.
    expect(prepared.messages[1].content).toBe('Give me a dinner idea');
  });

  it('records the memories each answer had in front of it', async () => {
    const diet = await h.store.add({
      text: 'User is vegetarian',
      origin: 'tool',
      kind: 'profile',
    });
    const prepared = await send([user('Give me a dinner idea')]);
    const meta = memoryMeta(prepared)!;
    expect(meta.injected).toEqual([
      {
        id: diet!.id,
        text: 'User is vegetarian',
        kind: 'profile',
        how: 'always',
      },
    ]);
    expect(meta.tokens).toBeGreaterThan(0);
    const use = await h.store.getUse(meta.useId!);
    expect(use).toMatchObject({sessionId: 'chat-1', messageId: null});
    expect(use!.items.map(item => item.memoryId)).toEqual([diet!.id]);
  });

  it('keeps the system message byte-identical for the whole chat', async () => {
    await h.store.add({
      text: 'User is vegetarian',
      origin: 'tool',
      kind: 'profile',
    });
    const first = await send([user('Give me a dinner idea')]);
    // A memory saved mid-chat does not move the cached prefix…
    await h.store.add({text: 'User has a dog called Rex', origin: 'tool'});
    // …nor does a memory being used (its rank changes).
    await h.store.confirmUse(memoryMeta(first)!.useId!, {
      citedIds: memoryMeta(first)!.injected.map(item => item.id),
    });
    const second = await send([
      user('Give me a dinner idea'),
      assistant('Chickpea curry.'),
      user('And for tomorrow?'),
    ]);
    expect(system(second)).toBe(system(first));
    expect(second.messages.slice(1, 3)).toEqual([
      user('Give me a dinner idea'),
      assistant('Chickpea curry.'),
    ]);
    // A new chat starts from the current list.
    const other = await send([user('Hi again')], {id: 'chat-2'});
    expect(system(other)).toContain('- User has a dog called Rex');
  });

  it('carries the snapshot over when a new chat gets its id', async () => {
    await h.store.add({
      text: 'User is vegetarian',
      origin: 'tool',
      kind: 'profile',
    });
    const first = await send([user('Give me a dinner idea')], {});
    await h.store.add({text: 'User has a dog called Rex', origin: 'tool'});
    const second = await send(
      [
        user('Give me a dinner idea'),
        assistant('Chickpea curry.'),
        user('And for tomorrow?'),
      ],
      {id: 'chat-9'},
    );
    expect(system(second)).toBe(system(first));
    // No chat id yet means no use record on disk for the first turn.
    expect(memoryMeta(first)!.useId).toBeUndefined();
    expect(memoryMeta(second)!.useId).toBeDefined();
  });

  it('drops a deleted or edited memory from an open chat at once', async () => {
    const diet = await h.store.add({
      text: 'User is vegetarian',
      origin: 'tool',
      kind: 'profile',
    });
    const home = await h.store.add({
      text: 'User lives in Lyon',
      origin: 'tool',
      kind: 'profile',
    });
    const first = await send([user('Give me a dinner idea')]);
    expect(system(first)).toContain('- User is vegetarian');
    await h.store.delete([diet!.id]);
    await h.store.update(home!.id, {text: 'User lives in Nantes'});
    const second = await send([
      user('Give me a dinner idea'),
      assistant('Chickpea curry.'),
      user('And for tomorrow?'),
    ]);
    expect(system(second)).not.toContain('vegetarian');
    expect(system(second)).not.toContain('Lyon');
    expect(system(second)).toContain('- User lives in Nantes');
    expect(memoryMeta(second)!.injected.map(item => item.id)).toEqual([
      home!.id,
    ]);
  });

  it('retrieves what did not fit, on the newest user message only', async () => {
    install({
      budget: () => ({
        alwaysTokens: 62,
        retrievedTokens: 80,
        maxRetrieved: 2,
        digestChats: 0,
        digestTokens: 0,
        searchChats: false,
      }),
    });
    await h.store.add({
      text: 'User is vegetarian',
      origin: 'tool',
      kind: 'profile',
    });
    const marathon = await h.store.add({
      text: 'User is training for a marathon in October',
      origin: 'extraction',
      kind: 'context',
    });
    await h.store.add({
      text: 'User is building a Flutter app for houseplants',
      origin: 'extraction',
      kind: 'context',
    });
    const history = [user('hi'), assistant('Hello!')];
    const prepared = await send([
      ...history,
      user('Can you adjust my marathon plan?'),
    ]);
    expect(system(prepared)).toContain('- User is vegetarian');
    expect(system(prepared)).not.toContain('marathon');
    expect(prepared.messages[prepared.messages.length - 1].content).toBe(
      `Can you adjust my marathon plan?\n\n[${RETRIEVED_PREFIX}User is training for a marathon in October]`,
    );
    // Earlier messages are exactly as they were: the cache holds.
    expect(prepared.messages.slice(1, 3)).toEqual(history);
    const meta = memoryMeta(prepared)!;
    expect(meta.injected.map(item => [item.id, item.how])).toContainEqual([
      marathon!.id,
      'retrieved',
    ]);
    expect(meta.injected).toHaveLength(2);
    const use = await h.store.getUse(meta.useId!);
    expect(use!.items.map(item => item.how).sort()).toEqual([
      'always',
      'retrieved',
    ]);
  });

  it('stays inside the token budget of the context window', async () => {
    for (let i = 0; i < 60; i++) {
      await h.store.add({
        text: `User fact number ${i}: likes the colour shade ${i} very much indeed`,
        origin: 'extraction',
        kind: 'profile',
      });
    }
    const small = memoryMeta(await send([user('hello')], {id: 'a'}, 4096))!;
    const large = memoryMeta(await send([user('hello')], {id: 'b'}, 16384))!;
    expect(small.tokens).toBeLessThanOrEqual(220);
    expect(small.injected.length).toBeGreaterThan(3);
    expect(large.tokens).toBeLessThanOrEqual(600);
    expect(large.injected.length).toBeGreaterThan(small.injected.length);
  });

  it('writes and reads nothing in a temporary chat', async () => {
    await h.store.add({
      text: 'User is vegetarian',
      origin: 'tool',
      kind: 'profile',
    });
    const prepared = await send([user('Give me a dinner idea')], {
      id: 'temp-1',
      temporary: true,
    });
    expect(system(prepared)).not.toContain('vegetarian');
    expect(prepared.tools).toEqual([]);
    expect(memoryMeta(prepared)).toBeUndefined();
    expect(await h.store.usesForSession('temp-1')).toEqual([]);
    // The model is told the truth, so it does not promise to remember.
    expect(system(prepared)).toContain(TEMPORARY_CHAT_NOTE);
    expect(prepared.messages[1].content).toBe('Give me a dinner idea');
    const asked = await send([user("Remember that I'm vegetarian")], {
      id: 'temp-1',
      temporary: true,
    });
    expect(asked.messages[1].content).toBe(
      `Remember that I'm vegetarian\n\n[${TEMPORARY_CHAT_REMINDER}]`,
    );
    expect(system(await send([user('hi')]))).not.toContain(TEMPORARY_CHAT_NOTE);
  });

  it('knows a chat is temporary from the conversation store too', async () => {
    await h.store.add({
      text: 'User is vegetarian',
      origin: 'tool',
      kind: 'profile',
    });
    const id = h.chats.up.addSession('Temp');
    await h.chats.store.markTemporary(id);
    const prepared = await send([user('Give me a dinner idea')], {id});
    expect(system(prepared)).not.toContain('vegetarian');
    expect(prepared.tools).toEqual([]);
  });

  it('a personalised temporary chat reads memories but cannot write', async () => {
    await h.store.updateSettings({personalizeTemporary: true});
    await h.store.add({
      text: 'User is vegetarian',
      origin: 'tool',
      kind: 'profile',
    });
    const prepared = await send([user('Give me a dinner idea')], {
      id: 'temp-1',
      temporary: true,
    });
    expect(system(prepared)).toContain('- User is vegetarian');
    expect(system(prepared)).not.toContain(MEMORY_TOOL_HINT);
    expect(toolNames(prepared)).toEqual(['search_chats']);
    expect(system(prepared)).toContain(TEMPORARY_CHAT_NOTE);
    expect(memoryMeta(prepared)!.useId).toBeUndefined();
    expect(await h.store.usesForSession('temp-1')).toEqual([]);
  });

  it('does nothing when memory is switched off; pause still reads', async () => {
    await h.store.add({
      text: 'User is vegetarian',
      origin: 'tool',
      kind: 'profile',
    });
    await h.store.setPaused(true);
    const paused = await send([user('Give me a dinner idea')]);
    expect(system(paused)).toContain('- User is vegetarian');
    expect(memoryMeta(paused)!.paused).toBe(true);
    // Paused: nothing can be written, so the write tools are not offered.
    expect(toolNames(paused)).not.toContain('save_memory');
    expect(toolNames(paused)).not.toContain('forget_memory');
    await h.store.updateSettings({enabled: false});
    const off = await send([
      user('Give me a dinner idea'),
      assistant('Curry.'),
      user('More?'),
    ]);
    expect(system(off)).not.toContain('vegetarian');
    expect(off.tools).toEqual([]);
    expect(memoryMeta(off)).toBeUndefined();
  });

  it('an offline chat reads memories but cannot write', async () => {
    await h.store.add({
      text: 'User is vegetarian',
      origin: 'tool',
      kind: 'profile',
    });
    const prepared = await send([user('Give me a dinner idea')], {
      id: 'chat-1',
      offline: true,
    } as {id: string});
    expect(system(prepared)).toContain('- User is vegetarian');
    expect(toolNames(prepared)).not.toContain('save_memory');
    expect(toolNames(prepared)).not.toContain('forget_memory');
  });

  it('tells the model it cannot save while paused', async () => {
    await h.store.setPaused(true);
    const prepared = await send([
      user('Please remember that I live in Lisbon'),
    ]);
    expect(JSON.stringify(prepared.messages)).toContain(MEMORY_PAUSED_REMINDER);
  });

  it('offers no chat search on a 4k context or with chat reference off', async () => {
    expect(toolNames(await send([user('hi')], {id: 'a'}, 4096))).toEqual([
      'save_memory',
      'forget_memory',
    ]);
    await h.store.updateSettings({referenceChats: false});
    expect(toolNames(await send([user('hi')], {id: 'b'}, 8192))).toEqual([
      'save_memory',
      'forget_memory',
    ]);
  });

  it('lists recent chats after the memories, from 8k up', async () => {
    await h.addChat('Trip to Lisbon', [
      ['Plan a 3 day trip to Lisbon in March', 'Day 1: Alfama…'],
    ]);
    await h.addChat('Sourdough', [
      ['Why is my sourdough starter flat?', 'Feed it…'],
    ]);
    await h.store.add({
      text: 'User is vegetarian',
      origin: 'tool',
      kind: 'profile',
    });
    const prepared = await send([user('hello')], {id: 'new-chat'});
    const text = system(prepared);
    expect(text).toContain(
      'Recent chats with the user, newest first (date, title: what the user asked). Call search_chats to look up details.',
    );
    expect(text).toMatch(
      /- \d+ \w+, Sourdough: Why is my sourdough starter flat\?/,
    );
    expect(text.indexOf('Sourdough')).toBeLessThan(
      text.indexOf('Trip to Lisbon'),
    );
    expect(text.indexOf(MEMORY_BLOCK_HEADER)).toBeLessThan(
      text.indexOf('Recent chats'),
    );
    expect(memoryMeta(prepared)!.recentChats).toBe(2);
    // Not on a 4k context.
    const small = await send([user('hello')], {id: 'new-chat-2'}, 4096);
    expect(system(small)).not.toContain('Recent chats');
    expect(memoryMeta(small)!.recentChats).toBe(0);
  });

  it('gives a project its own memories when it keeps them to itself', async () => {
    await h.db.run(
      `INSERT INTO projects (id, name, instructions, created_at, updated_at, memory_scope)
       VALUES ('p1', 'Thesis', '', 0, 0, 'project'), ('p2', 'Garden', '', 0, 0, 'default')`,
    );
    const isolated = await h.addChat('Thesis chat', [['hi', 'hello']]);
    const shared = await h.addChat('Garden chat', [['hi', 'hello']]);
    await h.chats.store.setProject(isolated, 'p1');
    await h.chats.store.setProject(shared, 'p2');
    await h.store.add({
      text: 'User is vegetarian',
      origin: 'tool',
      kind: 'profile',
    });
    await h.store.add({
      text: 'Thesis deadline is 1 March',
      origin: 'tool',
      projectId: 'p1',
    });
    const inIsolated = system(await send([user('status?')], {id: isolated}));
    expect(inIsolated).toContain('- Thesis deadline is 1 March');
    expect(inIsolated).not.toContain('vegetarian');
    // Its chats are not listed elsewhere, and it lists only its own.
    expect(inIsolated).not.toContain('Garden chat');
    const inShared = system(await send([user('status?')], {id: shared}));
    expect(inShared).toContain('- User is vegetarian');
    expect(inShared).not.toContain('Thesis');
    const outside = system(await send([user('status?')], {id: 'plain'}));
    expect(outside).toContain('- User is vegetarian');
    expect(outside).not.toContain('Thesis');
    expect(outside).toContain('Garden chat');
  });

  it('can run without the write tools or the hint', async () => {
    install({writeTools: false});
    const prepared = await send([user('hi')]);
    expect(toolNames(prepared)).toEqual(['search_chats']);
    expect(system(prepared)).not.toContain(MEMORY_TOOL_HINT);
    install({toolHint: false});
    expect(system(await send([user('hi')]))).not.toContain(MEMORY_TOOL_HINT);
  });
});
