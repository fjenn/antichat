import type {ChatEvent} from '..';
import {bucketFor, buildSections} from '../dateBuckets';
import {createFakePorts, fakeAnswerFor, fakeTokens} from '../fakes';

const DAY = 24 * 60 * 60 * 1000;

beforeEach(() => jest.useFakeTimers());
afterEach(() => jest.useRealTimers());

async function settle(ms = 60_000) {
  await jest.advanceTimersByTimeAsync(ms);
}

describe('date buckets', () => {
  const now = new Date(2026, 10, 24, 15, 0).getTime();

  it('puts a chat into the right drawer group', () => {
    expect(bucketFor(now - 60_000, now)).toBe('today');
    expect(bucketFor(now - 20 * 60 * 60 * 1000, now)).toBe('yesterday');
    expect(bucketFor(now - 3 * DAY, now)).toBe('previous7Days');
    expect(bucketFor(now - 20 * DAY, now)).toBe('previous30Days');
    expect(bucketFor(now - 90 * DAY, now)).toBe('older');
  });

  it('lists pinned chats first and hides archived and temporary ones', () => {
    const base = {
      createdAt: now,
      pinned: false,
      archived: false,
      temporary: false,
      locked: false,
    };
    const sections = buildSections(
      [
        {...base, id: 'a', title: 'A', updatedAt: now - 1000},
        {...base, id: 'b', title: 'B', updatedAt: now - 40 * DAY, pinned: true},
        {...base, id: 'c', title: 'C', updatedAt: now, archived: true},
        {...base, id: 'd', title: 'D', updatedAt: now, temporary: true},
        {...base, id: 'e', title: 'E', updatedAt: now - 500},
      ],
      now,
    );
    expect(sections.map(section => section.key)).toEqual(['pinned', 'today']);
    expect(sections[1].conversations.map(c => c.id)).toEqual(['e', 'a']);
  });
});

describe('FakeChat', () => {
  it('streams a markdown answer token by token', async () => {
    const {chat, conversations} = createFakePorts({
      conversations: {empty: true},
    });
    const result = await chat.send(null, {text: 'Explain transformers'});
    const events: ChatEvent[] = [];
    chat.listen(result.conversationId, event => events.push(event));

    expect(chat.isGenerating(result.conversationId)).toBe(true);
    expect(chat.messages(result.conversationId)[1].status).toBe('pending');

    await jest.advanceTimersByTimeAsync(1000);
    const partial = chat.messages(result.conversationId)[1];
    expect(partial.status).toBe('streaming');
    expect(partial.text.length).toBeGreaterThan(0);

    await settle();
    const [user, answer] = chat.messages(result.conversationId);
    expect(user).toMatchObject({role: 'user', text: 'Explain transformers'});
    expect(answer.status).toBe('complete');
    expect(answer.text).toBe(fakeAnswerFor('Explain transformers'));
    // The script exercises the constructs the thread must render mid-stream.
    expect(answer.text).toMatch(/^## /m);
    expect(answer.text).toContain('| --- |');
    expect(answer.text).toContain('$$');
    expect(chat.isGenerating(result.conversationId)).toBe(false);

    const deltas = events.filter(event => event.type === 'text_delta');
    expect(deltas.length).toBe(fakeTokens(answer.text).length);
    expect(events.at(-1)).toMatchObject({type: 'finished', status: 'complete'});
    // The new chat got a title and moved to the top of the list.
    expect(conversations.conversations[0].title).toBe('Explain transformers');
  });

  it('thinks first when asked to', async () => {
    const {chat} = createFakePorts();
    const {conversationId} = await chat.send(null, {
      text: 'Plan my week',
      thinking: true,
    });
    expect(chat.phase(conversationId)).toBe('thinking');
    await settle();
    const answer = chat.messages(conversationId)[1];
    expect(answer.reasoning?.text.length).toBeGreaterThan(0);
    expect(answer.reasoning?.durationMs).toBeGreaterThan(0);
    expect(chat.phase(conversationId)).toBeNull();
  });

  it('keeps the partial answer on stop', async () => {
    const {chat} = createFakePorts();
    const {conversationId} = await chat.send(null, {text: 'Explain tides'});
    await jest.advanceTimersByTimeAsync(1500);
    chat.stop(conversationId);
    const answer = chat.messages(conversationId)[1];
    expect(answer.status).toBe('stopped');
    expect(answer.text.length).toBeGreaterThan(0);
    const length = answer.text.length;
    await settle();
    expect(chat.messages(conversationId)[1].text.length).toBe(length);
  });

  it('regenerates into a second version and switches back', async () => {
    const {chat} = createFakePorts();
    const first = await chat.send(null, {text: 'Write a birthday note'});
    await settle();
    const second = await chat.regenerate(
      first.conversationId,
      first.assistantMessageId,
    );
    await settle();
    const thread = chat.messages(first.conversationId);
    expect(thread).toHaveLength(2);
    expect(thread[1].id).toBe(second.assistantMessageId);
    expect(thread[1].version).toEqual({index: 1, count: 2});

    await chat.switchVersion(first.conversationId, thread[1].id, 0);
    expect(chat.messages(first.conversationId)[1].id).toBe(
      first.assistantMessageId,
    );
    expect(chat.messages(first.conversationId)[1].version).toEqual({
      index: 0,
      count: 2,
    });
  });

  it('answers again after an edit', async () => {
    const {chat} = createFakePorts();
    const first = await chat.send(null, {text: 'Fix my test'});
    await settle();
    await chat.edit(first.conversationId, first.userMessageId, {
      text: 'Fix my Jest test please',
    });
    await settle();
    const thread = chat.messages(first.conversationId);
    expect(thread).toHaveLength(2);
    expect(thread[0].text).toBe('Fix my Jest test please');
    expect(thread[1].status).toBe('complete');
  });

  it('reports a failure as message state, not as a throw', async () => {
    const {chat} = createFakePorts();
    chat.failNext({code: 'out_of_memory', retryable: true});
    const {conversationId} = await chat.send(null, {text: 'Hello'});
    await settle();
    const answer = chat.messages(conversationId)[1];
    expect(answer.status).toBe('error');
    expect(answer.error).toEqual({code: 'out_of_memory', retryable: true});
  });
});

describe('FakeConversations', () => {
  it('starts with history in several date groups', () => {
    const {conversations} = createFakePorts();
    const keys = conversations.sections().map(section => section.key);
    expect(keys[0]).toBe('pinned');
    expect(keys).toEqual(expect.arrayContaining(['today', 'yesterday']));
  });

  it('pins, archives, deletes and finds chats', async () => {
    const {conversations} = createFakePorts();
    const listener = jest.fn();
    conversations.subscribe(listener);
    const target = conversations.conversations.find(c => !c.pinned)!;

    await conversations.setPinned(target.id, true);
    expect(conversations.sections()[0].conversations).toContainEqual(
      expect.objectContaining({id: target.id}),
    );
    await conversations.setArchived(target.id, true);
    expect(conversations.archived().map(c => c.id)).toEqual([target.id]);
    expect(
      conversations.sections().flatMap(s => s.conversations.map(c => c.id)),
    ).not.toContain(target.id);
    await conversations.remove(target.id);
    expect(conversations.get(target.id)).toBeUndefined();
    expect(listener).toHaveBeenCalledTimes(3);

    const hits = await conversations.search('lisbon');
    expect(hits).toHaveLength(1);
    expect(hits[0].matches).toEqual([[16, 22]]);
  });
});

describe('FakeModel', () => {
  it('starts with the recommended model loaded', () => {
    const {model} = createFakePorts();
    expect(model.activeModelId).toBe(model.recommendedModelId);
    expect(model.stateOf('fake-small').status).toBe('loaded');
    expect(model.capabilities?.vision.available).toBe(true);
  });

  it('downloads with progress, pauses, resumes and loads', async () => {
    const {model} = createFakePorts({model: {fresh: true}});
    expect(model.stateOf('fake-small').status).toBe('not_installed');
    const done = model.download('fake-small');
    await jest.advanceTimersByTimeAsync(1000);
    const state = model.stateOf('fake-small');
    expect(state.status).toBe('downloading');
    if (state.status !== 'downloading') {
      throw new Error('not downloading');
    }
    expect(state.progress.fraction).toBeGreaterThan(0);
    expect(state.progress.fraction).toBeLessThan(1);

    model.pause('fake-small');
    expect(model.stateOf('fake-small')).toMatchObject({
      paused: true,
      pauseReason: 'user',
    });
    const resumed = model.resume('fake-small');
    await settle();
    await Promise.race([done, resumed]);
    expect(model.stateOf('fake-small').status).toBe('ready');

    const loading = model.load('fake-small');
    expect(model.stateOf('fake-small').status).toBe('loading');
    await settle();
    await loading;
    expect(model.stateOf('fake-small').status).toBe('loaded');
    expect(model.models[0].state.status).toBe('loaded');
  });

  it('shows a notice instead of an alert when memory runs low', async () => {
    const {model} = createFakePorts();
    const loading = model.load('fake-large');
    await settle();
    await loading;
    const pressure = model.onMemoryPressure('critical', {
      generating: false,
      aux: [],
    });
    await settle();
    await pressure;
    expect(model.activeModelId).toBe('fake-small');
    expect(model.notices[0]).toMatchObject({kind: 'low_memory_switched'});
    model.dismissNotice(model.notices[0].id);
    expect(model.notices).toHaveLength(0);
  });
});

describe('the other fakes', () => {
  it('greys out online tools while offline', () => {
    const {tools, connectivity} = createFakePorts();
    expect(tools.tools.find(t => t.id === 'research')?.available).toBe(true);
    connectivity.set(false);
    const search = tools.tools.find(t => t.id === 'search');
    expect(search).toMatchObject({
      available: false,
      unavailableReason: 'offline',
    });
    expect(tools.tools.find(t => t.id === 'think')?.available).toBe(true);
  });

  it('keeps active tools per chat', () => {
    const {tools} = createFakePorts();
    tools.setActive(null, 'search', true);
    tools.setActive('c1', 'think', true);
    expect(tools.activeToolIds(null)).toEqual(['search']);
    expect(tools.activeToolIds('c1')).toEqual(['think']);
    tools.clearActive(null);
    expect(tools.activeToolIds(null)).toEqual([]);
  });

  it('adds and removes memories', async () => {
    const {memory} = createFakePorts();
    const count = memory.memories.length;
    const added = await memory.add('  Lives in Porto ');
    expect(added.text).toBe('Lives in Porto');
    expect(memory.memories).toHaveLength(count + 1);
    await memory.remove(added.id);
    expect(memory.memories).toHaveLength(count);
  });

  it('gets an attachment ready after a moment', async () => {
    const {files} = createFakePorts();
    const [draft] = await files.pick(null, 'files');
    expect(draft.state.status).toBe('processing');
    await settle(1000);
    expect(files.drafts(null)[0].state).toMatchObject({
      status: 'ready',
      mode: 'inline',
    });
    files.remove(null, draft.attachment.id);
    expect(files.drafts(null)).toHaveLength(0);
  });

  it('hears a phrase word by word while dictating', async () => {
    const {voice} = createFakePorts();
    await voice.startDictation();
    await settle(700);
    expect(voice.dictation).toMatchObject({status: 'listening'});
    const text = await voice.finishDictation();
    expect(text.split(' ').length).toBe(3);
    expect(voice.dictation.status).toBe('idle');
  });
});
