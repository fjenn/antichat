import type {DeviceClass} from '../../prompt/types';
import {EXTRACTION_RULES} from '../extraction';
import {DIGEST_SYSTEM_PROMPT} from '../digest';
import {MemoryScheduler, passPolicyFor, type ModelLease} from '../scheduler';
import {createChatHarness, type ChatHarness} from './support/memoryHarness';
import {
  createScriptedEngine,
  type Script,
  type ScriptedEngine,
} from './support/scriptedEngine';

const facts = (...texts: string[]) =>
  JSON.stringify({
    memories: texts.map(text => ({text, type: 'profile', private: false})),
  });

describe('MemoryScheduler (idle pass)', () => {
  let h: ChatHarness;
  let engine: ScriptedEngine;
  let script: Script;
  let busy: boolean;
  let leases: number;
  let ended: number;
  let controller: AbortController;
  let deviceClass: DeviceClass;
  let scheduler: MemoryScheduler;

  const QUIET = 60_000;

  beforeEach(async () => {
    h = await createChatHarness();
    busy = false;
    leases = 0;
    ended = 0;
    deviceClass = 'C';
    controller = new AbortController();
    script = call =>
      call.system === DIGEST_SYSTEM_PROMPT
        ? 'Note about the chat, written by the model.'
        : facts();
    engine = createScriptedEngine(call => script(call));
    scheduler = new MemoryScheduler({
      db: h.db,
      store: h.store,
      writer: h.writer,
      digests: h.digests,
      acquireModel: (): ModelLease | null => {
        if (busy) {
          return null;
        }
        leases++;
        return {
          engine,
          family: 'lfm3',
          signal: controller.signal,
          end: () => {
            ended++;
          },
        };
      },
      deviceClass: () => deviceClass,
      now: () => h.clock.now,
      quietMs: QUIET,
    });
  });
  afterEach(() => h.close());

  const memories = async () =>
    (await h.store.list()).map(memory => memory.text).sort();
  const extractionCalls = () =>
    engine.calls.filter(call => call.system === EXTRACTION_RULES);
  const rest = () => {
    h.clock.now += QUIET + 1000;
  };

  it('reads a finished chat once it has gone quiet', async () => {
    const chat = await h.addChat('Dinner', [
      ["I'm vegetarian and I live in Lyon. Dinner ideas?", 'Chickpea curry.'],
    ]);
    script = call =>
      call.system === EXTRACTION_RULES
        ? facts('User is vegetarian.', 'User lives in Lyon.')
        : 'Vegetarian dinner ideas in Lyon.';
    // Still warm: not yet.
    expect(await scheduler.pendingChats()).toEqual([]);
    expect((await scheduler.runPass()).reason).toBe('nothing');
    rest();
    expect((await scheduler.pendingChats()).map(c => c.sessionId)).toEqual([
      chat,
    ]);
    const result = await scheduler.runPass();
    expect(result).toMatchObject({ran: true, chats: 1, aborted: false});
    expect(result.saved.map(r => r.status)).toEqual(['added', 'added']);
    expect(await memories()).toEqual([
      'User is vegetarian.',
      'User lives in Lyon.',
    ]);
    expect((await h.store.list())[0]).toMatchObject({
      origin: 'extraction',
      sourceSessionId: chat,
    });
    // Only the user's words went to the model.
    expect(extractionCalls()[0].last).toBe(
      "User messages:\n1. I'm vegetarian and I live in Lyon. Dinner ideas?",
    );
    expect(await h.digests.get(chat)).toMatchObject({
      digest: 'Vegetarian dinner ideas in Lyon.',
      source: 'model',
    });
    expect(leases).toBe(1);
    expect(ended).toBe(1);
  });

  it('never reads the same messages twice, only what is new', async () => {
    const chat = await h.addChat('Dinner', [["I'm vegetarian.", 'Noted.']]);
    rest();
    await scheduler.runPass();
    expect(extractionCalls()).toHaveLength(1);
    rest();
    expect((await scheduler.runPass()).reason).toBe('nothing');
    expect(extractionCalls()).toHaveLength(1);
    h.chats.up.say(chat, 'I also have a dog called Rex.');
    h.chats.up.answer(chat, 'Nice.');
    await h.chats.store.syncSession(chat);
    rest();
    await scheduler.runPass();
    expect(extractionCalls()).toHaveLength(2);
    expect(extractionCalls()[1].last).toBe(
      'User messages:\n1. I also have a dog called Rex.',
    );
  });

  it('does not bring back a memory the user deleted from an old chat', async () => {
    await h.addChat('Dinner', [["I'm vegetarian.", 'Noted.']]);
    script = () => facts('User is vegetarian.');
    rest();
    await scheduler.runPass();
    await h.store.delete((await h.store.list()).map(m => m.id));
    rest();
    await scheduler.runPass();
    // A later chat repeats it in passing: still not saved.
    await h.addChat('Lunch', [['A vegetarian lunch idea please', 'Falafel.']]);
    rest();
    await scheduler.runPass();
    expect(await memories()).toEqual([]);
  });

  it('an old "remember that" does not undo a later deletion; a new one does', async () => {
    // Saved by the tool during the chat, before the idle pass ever ran.
    const saved = await h.writer.save({
      text: 'User is vegetarian.',
      origin: 'tool',
      explicit: true,
    });
    await h.addChat('Old', [["Remember that I'm vegetarian", 'Saved.']]);
    await h.store.delete([saved.memory!.id], 'user');
    script = call =>
      call.system === EXTRACTION_RULES
        ? facts('User is vegetarian.')
        : 'A note.';
    rest();
    const pass = await scheduler.runPass();
    expect(pass.saved.map(r => r.status)).toEqual(['blocked']);
    expect(await memories()).toEqual([]);
    // Asked again now: it is saved again.
    const again = await scheduler.captureExplicit({
      sessionId: 'new-chat',
      userText: "Remember that I'm vegetarian",
      toolSaved: false,
    });
    expect(again?.map(r => r.status)).toEqual(['added']);
  });

  it('never reads a temporary chat', async () => {
    const temp = h.chats.up.addSession('Temp');
    await h.chats.store.markTemporary(temp);
    h.chats.up.say(temp, 'Remember that my PIN is 4321 and I live in Lyon.');
    h.chats.up.answer(temp, 'Ok.');
    await h.chats.store.syncSession(temp);
    script = () => facts('User lives in Lyon.');
    rest();
    expect(await scheduler.pendingChats()).toEqual([]);
    expect(await scheduler.runPass({leaving: temp})).toMatchObject({
      reason: 'nothing',
    });
    expect(engine.calls).toEqual([]);
    expect(await memories()).toEqual([]);
    // Nothing about it anywhere in the memory tables.
    for (const table of ['memory_extraction', 'chat_digests', 'memory_uses']) {
      expect(await h.db.all(`SELECT * FROM ${table}`)).toEqual([]);
    }
    expect(
      await scheduler.captureExplicit({
        sessionId: temp,
        userText: 'Remember that I live in Lyon.',
        toolSaved: false,
      }),
    ).toBeNull();
  });

  it('reads the chat the user just left, and skips the one on screen', async () => {
    const left = await h.addChat('Left', [["I'm a nurse.", 'Ok.']]);
    const current = await h.addChat('Current', [['I live in Rome.', 'Ok.']]);
    script = call =>
      call.last.includes('nurse')
        ? facts('User is a nurse.')
        : facts('User lives in Rome.');
    const result = await scheduler.runPass({leaving: left, current});
    expect(result.chats).toBe(1);
    expect(await memories()).toEqual(['User is a nurse.']);
    // Even when quiet, the open chat is left for later: its prompt cache
    // would be lost to the side job.
    rest();
    expect((await scheduler.runPass({current})).reason).toBe('nothing');
    expect(await scheduler.runPass({leaving: current})).toMatchObject({
      chats: 1,
    });
    expect(await memories()).toEqual([
      'User is a nurse.',
      'User lives in Rome.',
    ]);
  });

  it('reads the chat on screen once it has been quiet for ten minutes', async () => {
    const current = await h.addChat('Current', [['I live in Rome.', 'Ok.']]);
    script = call =>
      call.system === EXTRACTION_RULES
        ? facts('User lives in Rome.')
        : 'A note.';
    h.clock.now += 9 * 60_000;
    expect((await scheduler.runPass({current})).reason).toBe('nothing');
    h.clock.now += 2 * 60_000;
    expect((await scheduler.runPass({current})).chats).toBe(1);
  });

  it('steps aside when the model is busy and tries again later', async () => {
    const chat = await h.addChat('Dinner', [["I'm vegetarian.", 'Noted.']]);
    script = call =>
      call.system === EXTRACTION_RULES
        ? facts('User is vegetarian.')
        : 'A note.';
    rest();
    busy = true;
    const first = await scheduler.runPass();
    expect(first).toMatchObject({reason: 'busy', chats: 0});
    expect(await memories()).toEqual([]);
    // The rule-based digest needed no model.
    expect(await h.digests.get(chat)).toMatchObject({
      digest: "I'm vegetarian.",
      source: 'rule',
    });
    busy = false;
    expect((await scheduler.runPass()).chats).toBe(1);
    expect(await memories()).toEqual(['User is vegetarian.']);
  });

  it('gives the model back at once when the user starts typing', async () => {
    await h.addChat('A', [["I'm vegetarian.", 'Noted.']]);
    await h.addChat('B', [['I live in Rome.', 'Ok.']]);
    script = () => {
      controller.abort();
      return facts('User is vegetarian.');
    };
    rest();
    const result = await scheduler.runPass();
    expect(result.aborted).toBe(true);
    expect(result.chats).toBe(0);
    expect(ended).toBe(1);
    expect(await memories()).toEqual([]);
    // Nothing was marked as read: the next pass starts over.
    controller = new AbortController();
    script = call =>
      call.system === EXTRACTION_RULES
        ? facts('User is vegetarian.')
        : 'A note.';
    expect((await scheduler.runPass()).chats).toBe(2);
  });

  it('retries a chat whose extraction failed', async () => {
    await h.addChat('A', [["I'm vegetarian.", 'Noted.']]);
    script = () => {
      throw new Error('context lost');
    };
    rest();
    expect((await scheduler.runPass()).chats).toBe(0);
    script = call =>
      call.system === EXTRACTION_RULES
        ? facts('User is vegetarian.')
        : 'A note.';
    expect((await scheduler.runPass()).chats).toBe(1);
  });

  it('while paused marks chats as read without mining them', async () => {
    await h.addChat('A', [["I'm vegetarian.", 'Noted.']]);
    await h.store.setPaused(true);
    script = call =>
      call.system === EXTRACTION_RULES
        ? facts('User is vegetarian.')
        : 'A note.';
    rest();
    await scheduler.runPass();
    expect(extractionCalls()).toHaveLength(0);
    await h.store.setPaused(false);
    rest();
    // What was said while paused stays unsaved.
    expect((await scheduler.runPass()).reason).toBe('nothing');
    expect(await memories()).toEqual([]);
  });

  it('does nothing at all when memory is off', async () => {
    await h.addChat('A', [["I'm vegetarian.", 'Noted.']]);
    await h.store.updateSettings({enabled: false});
    rest();
    expect(await scheduler.runPass()).toMatchObject({
      ran: false,
      reason: 'off',
    });
    expect(leases).toBe(0);
  });

  it('honours the auto-extract and chat-reference switches separately', async () => {
    const chat = await h.addChat('A', [["I'm vegetarian.", 'Noted.']]);
    await h.store.updateSettings({autoExtract: false});
    rest();
    await scheduler.runPass();
    expect(extractionCalls()).toHaveLength(0);
    expect((await h.digests.get(chat))?.source).toBe('model');
    const other = await h.addChat('B', [['I live in Rome.', 'Ok.']]);
    await h.store.updateSettings({autoExtract: true, referenceChats: false});
    rest();
    await scheduler.runPass();
    expect(extractionCalls()).toHaveLength(1);
    expect(await h.digests.get(other)).toBeNull();
  });

  it('on a 4 GB phone extracts too, but leaves digests to the rule', async () => {
    expect(passPolicyFor('A')).toEqual({extract: true, modelDigests: false});
    expect(passPolicyFor('B')).toEqual({extract: true, modelDigests: true});
    deviceClass = 'A';
    const chat = await h.addChat('A', [["I'm vegetarian.", 'Noted.']]);
    script = () => facts('User is vegetarian.');
    rest();
    const result = await scheduler.runPass();
    expect(result).toMatchObject({ran: true, chats: 1});
    expect(await memories()).toEqual(['User is vegetarian.']);
    expect(engine.calls).toHaveLength(1);
    expect((await h.digests.get(chat))?.source).toBe('rule');
    expect(await scheduler.pendingChats()).toEqual([]);
  });

  it('can be told to leave extraction to the tool on a device class', async () => {
    const toolOnly = new MemoryScheduler({
      db: h.db,
      store: h.store,
      writer: h.writer,
      digests: h.digests,
      acquireModel: () => {
        leases++;
        return {engine, end: () => {}};
      },
      now: () => h.clock.now,
      quietMs: QUIET,
      policy: () => ({extract: false, modelDigests: false}),
    });
    const chat = await h.addChat('A', [["I'm vegetarian.", 'Noted.']]);
    rest();
    expect(await toolOnly.runPass()).toMatchObject({ran: true, chats: 1});
    expect(leases).toBe(0);
    expect(engine.calls).toEqual([]);
    expect((await h.digests.get(chat))?.source).toBe('rule');
    expect(await toolOnly.pendingChats()).toEqual([]);
  });

  it('reads at most a few chats per pass, newest first', async () => {
    const ids: string[] = [];
    for (let i = 0; i < 6; i++) {
      ids.push(await h.addChat(`Chat ${i}`, [[`I like hobby ${i}.`, 'Ok.']]));
    }
    rest();
    expect((await scheduler.runPass()).chats).toBe(4);
    expect((await scheduler.pendingChats()).map(c => c.sessionId)).toEqual([
      ids[1],
      ids[0],
    ]);
    expect((await scheduler.runPass()).chats).toBe(2);
  });

  it('lets the model tidy memories the tool saved while it was busy', async () => {
    await h.writer.save({
      text: 'User is training for a marathon',
      origin: 'tool',
    });
    await h.writer.save({
      text: 'User stopped marathon training',
      origin: 'tool',
    });
    expect(await h.store.needingReview()).toHaveLength(1);
    script = () => '{"id":"m1","relation":"replaces"}';
    const result = await scheduler.runPass();
    expect(result).toMatchObject({ran: true, reviewed: 1, chats: 0});
    expect(await memories()).toEqual(['User stopped marathon training']);
  });

  it('does not rewrite the digest of a chat that was taken off the list', async () => {
    const chat = await h.addChat('Dinner', [
      ["I'm vegetarian. Dinner ideas?", 'Curry.'],
    ]);
    script = call =>
      call.system === EXTRACTION_RULES
        ? facts('User is vegetarian.')
        : 'Vegetarian dinner ideas.';
    rest();
    await scheduler.runPass();
    await h.store.delete((await h.store.list()).map(m => m.id));
    expect((await h.digests.get(chat))?.source).toBe('suppressed');
    h.chats.up.say(chat, 'And for lunch?');
    h.chats.up.answer(chat, 'Falafel.');
    await h.chats.store.syncSession(chat);
    rest();
    await scheduler.runPass();
    expect(await h.digests.get(chat)).toMatchObject({
      source: 'suppressed',
      digest: '',
    });
    expect(await h.digests.recent({limit: 5})).toEqual([]);
  });

  it('removes rows about chats that no longer exist', async () => {
    const chat = await h.addChat('A', [["I'm vegetarian.", 'Noted.']]);
    rest();
    await scheduler.runPass();
    await h.store.add({text: 'User is vegetarian', origin: 'user'});
    await h.store.recordUse(chat, [
      {memoryId: (await h.store.list())[0].id, how: 'always'},
    ]);
    await h.chats.store.deleteSessions([chat]);
    rest();
    await scheduler.runPass();
    for (const table of ['memory_extraction', 'chat_digests', 'memory_uses']) {
      expect(await h.db.all(`SELECT * FROM ${table}`)).toEqual([]);
    }
    // The memory itself outlives the chat it came from.
    expect(await h.store.count()).toBe(1);
  });

  describe('captureExplicit', () => {
    it('saves what the user asked to remember when the model did not call the tool', async () => {
      script = () => facts('User has celiac disease.');
      const results = await scheduler.captureExplicit({
        sessionId: 'chat-1',
        userText: 'Please remember that I have celiac disease.',
        toolSaved: false,
      });
      expect(results?.map(r => r.status)).toEqual(['added']);
      expect((await h.store.list())[0]).toMatchObject({
        text: 'User has celiac disease.',
        importance: 0.9,
        sourceSessionId: 'chat-1',
      });
      expect(ended).toBe(1);
    });

    it('does nothing without a request, after a tool save, or when busy', async () => {
      script = () => facts('User lives in Rome.');
      const base = {sessionId: 'chat-1', toolSaved: false};
      expect(
        await scheduler.captureExplicit({...base, userText: 'I live in Rome.'}),
      ).toBeNull();
      expect(
        await scheduler.captureExplicit({
          sessionId: 'chat-1',
          userText: 'Remember that I live in Rome.',
          toolSaved: true,
        }),
      ).toBeNull();
      busy = true;
      expect(
        await scheduler.captureExplicit({
          ...base,
          userText: 'Remember that I live in Rome.',
        }),
      ).toBeNull();
      await h.store.setPaused(true);
      busy = false;
      expect(
        await scheduler.captureExplicit({
          ...base,
          userText: 'Remember that I live in Rome.',
        }),
      ).toBeNull();
      expect(engine.calls).toEqual([]);
    });
  });
});
