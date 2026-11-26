import type {ChatEvent} from '../../contracts';
import {META, UpstreamChat} from '../chat';
import {FakeChatUpstream, settle} from './support/fakeChatUpstream';

function setup(options: {now?: () => number} = {}) {
  const upstream = new FakeChatUpstream();
  const chat = new UpstreamChat(upstream, options);
  chat.start();
  return {upstream, chat};
}

function record(chat: UpstreamChat, conversationId: string) {
  const events: ChatEvent[] = [];
  const off = chat.listen(conversationId, event => events.push(event));
  return {events, off};
}

const types = (events: ChatEvent[]) => events.map(event => event.type);

describe('UpstreamChat: reading a stored chat', () => {
  it('returns the thread oldest first although upstream keeps it newest first', () => {
    const {upstream, chat} = setup();
    upstream.seed('c1', [
      upstream.user('First question', 'u1'),
      upstream.turn([{content: 'First answer'}], {}, 'a1'),
      upstream.user('Second question', 'u2'),
      upstream.turn([{content: 'Second answer'}], {}, 'a2'),
    ]);
    upstream.open('c1');

    expect(
      chat.messages('c1').map(m => [m.id, m.role, m.text, m.status]),
    ).toEqual([
      ['u1', 'user', 'First question', 'complete'],
      ['a1', 'assistant', 'First answer', 'complete'],
      ['u2', 'user', 'Second question', 'complete'],
      ['a2', 'assistant', 'Second answer', 'complete'],
    ]);
  });

  it('maps a chat that is not the open one without watching it', () => {
    const {upstream, chat} = setup();
    upstream.seed('c1', [upstream.user('Hi', 'u1')]);
    expect(chat.messages('c1').map(m => m.id)).toEqual(['u1']);
    expect(chat.messages('missing')).toEqual([]);
  });

  it('separates thinking, cleans leaked markup and reads stored extras', () => {
    const {upstream, chat} = setup();
    upstream.seed('c1', [
      upstream.user('Why?', 'u1'),
      upstream.turn(
        [{content: 'Because.<|im_end|>', reasoningContent: 'Let me think.'}],
        {[META.thinkingMs]: 4200, [META.feedback]: 'up', [META.modelId]: 'q'},
        'a1',
      ),
      upstream.user('And inline?', 'u2'),
      upstream.turn(
        [{content: '<think>hidden plan</think>Visible answer'}],
        {},
        'a2',
      ),
    ]);
    upstream.open('c1');
    const [, first, , second] = chat.messages('c1');

    expect(first.text).toBe('Because.');
    expect(first.reasoning).toEqual({text: 'Let me think.', durationMs: 4200});
    expect(first.feedback).toBe('up');
    expect(first.modelId).toBe('q');
    expect(second.text).toBe('Visible answer');
    expect(second.reasoning?.text).toBe('hidden plan');
  });

  it('maps stopped, failed and system rows to typed states', () => {
    const {upstream, chat} = setup();
    upstream.seed('c1', [
      upstream.user('One', 'u1'),
      upstream.turn([{content: 'Half an'}], {[META.stopped]: true}, 'a1'),
      upstream.user('Two', 'u2'),
      upstream.turn(
        [{content: 'Cut'}],
        {interrupted: true, truncationLikely: true},
        'a2',
      ),
      upstream.user('Three', 'u3'),
      upstream.system('Completion failed: boom', 's1'),
      upstream.system('Conversation reset!', 's2'),
      upstream.user('Four', 'u4'),
      upstream.system('Model not loaded. Please initialize the model.', 's3'),
    ]);
    upstream.open('c1');
    const byId = new Map(chat.messages('c1').map(m => [m.id, m]));

    expect(byId.get('a1')?.status).toBe('stopped');
    expect(byId.get('a1')?.text).toBe('Half an');
    expect(byId.get('a2')?.status).toBe('error');
    expect(byId.get('a2')?.error).toEqual({
      code: 'context_full',
      retryable: true,
    });
    expect(byId.get('s1')).toMatchObject({
      role: 'assistant',
      status: 'error',
      text: '',
      error: {code: 'failed', detail: 'Completion failed: boom'},
    });
    // A row that is not an error is not shown at all.
    expect(byId.has('s2')).toBe(false);
    expect(byId.get('s3')?.error?.code).toBe('model_not_loaded');
  });

  it('adds a retry row under a question nothing answered', () => {
    const {upstream, chat} = setup();
    upstream.seed('c1', [upstream.user('Anyone?', 'u1')]);
    upstream.open('c1');
    const views = chat.messages('c1');

    expect(views).toHaveLength(2);
    expect(views[1]).toMatchObject({
      id: 'u1:unanswered',
      role: 'assistant',
      status: 'error',
      error: {code: 'failed', retryable: true},
    });
  });

  it('keeps arrays and messages identical while nothing changed', () => {
    const {upstream, chat} = setup();
    upstream.seed('c1', [
      upstream.user('Q', 'u1'),
      upstream.turn([{content: 'A'}], {}, 'a1'),
    ]);
    upstream.open('c1');
    const before = chat.messages('c1');
    upstream.emitStoreChange();
    expect(chat.messages('c1')).toBe(before);

    // One row changes: the others keep their objects.
    return upstream
      .updateMetadata('c1', 'a1', {[META.feedback]: 'down'})
      .then(() => {
        const after = chat.messages('c1');
        expect(after).not.toBe(before);
        expect(after[0]).toBe(before[0]);
        expect(after[1]).not.toBe(before[1]);
        expect(after[1].feedback).toBe('down');
      });
  });

  it('shows version positions once the store has them, only above one', async () => {
    const {upstream, chat} = setup();
    upstream.seed('c1', [
      upstream.user('Q', 'u1'),
      upstream.turn([{content: 'A'}], {}, 'a1'),
    ]);
    upstream.versionMap.set('u1', {index: 0, count: 1});
    upstream.versionMap.set('a1', {index: 1, count: 3});
    upstream.open('c1');
    await settle();

    const [question, answer] = chat.messages('c1');
    expect(question.version).toBeUndefined();
    expect(answer.version).toEqual({index: 1, count: 3});

    const notified = jest.fn();
    chat.subscribe(notified);
    upstream.versionMap.set('a1', {index: 2, count: 3});
    upstream.emitStoreChange();
    await settle();
    expect(chat.messages('c1')[1].version).toEqual({index: 2, count: 3});
    expect(notified).toHaveBeenCalled();
  });
});

describe('UpstreamChat: sending and streaming', () => {
  it('resolves as soon as the answer row exists and streams deltas', async () => {
    const {upstream, chat} = setup();
    const result = await chat.send(null, {text: 'Hello'});

    expect(result.conversationId).toBe(upstream.activeSessionId());
    const views = chat.messages(result.conversationId);
    expect(views.map(m => [m.id, m.role, m.status])).toEqual([
      [result.userMessageId, 'user', 'complete'],
      [result.assistantMessageId, 'assistant', 'pending'],
    ]);
    expect(chat.isGenerating(result.conversationId)).toBe(true);
    expect(chat.phase(result.conversationId)).toBe('writing');

    const {events} = record(chat, result.conversationId);
    const coarse = jest.fn();
    chat.subscribe(coarse);

    upstream.token({content: 'Hel'});
    // pending → streaming is a change of the row, with the text in it.
    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({
      type: 'message_updated',
      message: {status: 'streaming', text: 'Hel'},
    });
    const coarseAfterFirst = coarse.mock.calls.length;
    expect(coarseAfterFirst).toBeGreaterThan(0);

    upstream.token({content: 'Hello'});
    upstream.token({content: 'Hello there'});
    // Same content written again: nothing to say.
    upstream.token({content: 'Hello there'});
    expect(events.slice(1)).toEqual([
      {
        type: 'text_delta',
        messageId: result.assistantMessageId,
        delta: 'lo',
      },
      {
        type: 'text_delta',
        messageId: result.assistantMessageId,
        delta: ' there',
      },
    ]);
    // Tokens never reach the coarse subscription.
    expect(coarse.mock.calls.length).toBe(coarseAfterFirst);
    expect(chat.messages(result.conversationId)[1].text).toBe('Hello there');

    upstream.finish();
    await settle();
    expect(types(events).slice(-2)).toEqual(['message_updated', 'finished']);
    expect(events[events.length - 1]).toEqual({
      type: 'finished',
      messageId: result.assistantMessageId,
      status: 'complete',
    });
    expect(chat.messages(result.conversationId)[1].status).toBe('complete');
    expect(chat.isGenerating(result.conversationId)).toBe(false);
    expect(chat.phase(result.conversationId)).toBeNull();
    expect(coarse.mock.calls.length).toBeGreaterThan(coarseAfterFirst);
  });

  it('replaces instead of appending when the clean-up rewrites shown text', async () => {
    const {upstream, chat} = setup();
    const result = await chat.send(null, {text: 'Go'});
    const {events} = record(chat, result.conversationId);

    upstream.token({content: 'Answer '});
    upstream.token({content: 'Answer <'});
    // "<" may be the start of a marker; it turned out to be markup that is
    // stripped, so the text so far stays and nothing odd was shown.
    upstream.token({content: 'Answer <|im_end|>'});
    expect(
      events.every(
        event => event.type !== 'text_delta' || event.delta.length > 0,
      ),
    ).toBe(true);

    // Now the visible text really changes under what was already emitted.
    upstream.token({content: 'Different start'});
    const last = events[events.length - 1];
    expect(last).toMatchObject({
      type: 'message_updated',
      message: {text: 'Different start', status: 'streaming'},
    });

    upstream.token({content: 'Different start, continued'});
    expect(events[events.length - 1]).toEqual({
      type: 'text_delta',
      messageId: result.assistantMessageId,
      delta: ', continued',
    });
  });

  it('reports thinking as its own phase and measures how long it took', async () => {
    let now = 1000;
    const {upstream, chat} = setup({now: () => now});
    const result = await chat.send(null, {text: 'Think', thinking: true});
    expect(upstream.thinking).toBe(true);
    const {events} = record(chat, result.conversationId);

    upstream.token({reasoningContent: 'Hm'});
    expect(chat.phase(result.conversationId)).toBe('thinking');
    upstream.token({reasoningContent: 'Hm, right'});
    expect(events).toContainEqual({
      type: 'reasoning_delta',
      messageId: result.assistantMessageId,
      delta: ', right',
    });
    expect(events).toContainEqual(
      expect.objectContaining({type: 'phase', phase: 'thinking'}),
    );

    now = 4000;
    upstream.token({reasoningContent: 'Hm, right', content: 'So'});
    expect(chat.phase(result.conversationId)).toBe('writing');
    expect(chat.messages(result.conversationId)[1].reasoning).toEqual({
      text: 'Hm, right',
      durationMs: 3000,
    });

    upstream.finish();
    await settle();
    expect(upstream.calls).toContainEqual(
      expect.stringContaining(`metadata:${result.assistantMessageId}:`),
    );
    const stored = upstream
      .messagesOf(result.conversationId)!
      .find(row => row.id === result.assistantMessageId);
    expect(stored?.metadata?.[META.thinkingMs]).toBe(3000);
    expect(stored?.metadata?.[META.modelId]).toBe('model-1');
  });

  it('thinking is off unless the message asks for it', async () => {
    const {upstream, chat} = setup();
    await chat.send(null, {text: 'Plain'});
    expect(upstream.thinking).toBe(false);
  });

  it('passes image attachments on as image paths', async () => {
    const {chat} = setup();
    const result = await chat.send(null, {
      text: 'Look',
      attachments: [
        {id: 'f1', kind: 'image', name: 'a.jpg', uri: 'file:///a.jpg'},
        {id: 'f2', kind: 'document', name: 'b.pdf', uri: 'file:///b.pdf'},
      ],
    });
    const [question] = chat.messages(result.conversationId);
    expect(question.attachments?.map(a => a.uri)).toEqual(['file:///a.jpg']);
  });

  it('keeps the message and explains itself when no model can be loaded', async () => {
    const {upstream, chat} = setup();
    upstream.readiness = 'none';
    const result = await chat.send(null, {text: 'Hello?'});

    expect(upstream.calls).not.toContainEqual(expect.stringMatching(/^send:/));
    const views = chat.messages(result.conversationId);
    expect(views.map(m => [m.role, m.status, m.text])).toEqual([
      ['user', 'complete', 'Hello?'],
      ['assistant', 'error', ''],
    ]);
    expect(views[1].id).toBe(result.assistantMessageId);
    expect(views[1].error).toMatchObject({
      code: 'model_not_loaded',
      retryable: true,
    });

    // Retry once a model is there: the question is asked again.
    upstream.readiness = 'ready';
    const retry = await chat.regenerate(
      result.conversationId,
      result.assistantMessageId,
    );
    expect(upstream.calls.slice(-4)).toEqual([
      `remove:${result.userMessageId}:true`,
      'ensureModel',
      'thinking:false',
      'send:Hello?',
    ]);
    expect(
      chat.messages(retry.conversationId).map(m => [m.role, m.status]),
    ).toEqual([
      ['user', 'complete'],
      ['assistant', 'pending'],
    ]);
  });

  it('survives upstream giving up without an answer row', async () => {
    const {upstream, chat} = setup();
    upstream.createsTurn = false;
    const result = await chat.send(null, {text: 'Hi'});
    await settle();
    const views = chat.messages(result.conversationId);
    expect(views[views.length - 1]).toMatchObject({
      id: result.assistantMessageId,
      status: 'error',
      error: {code: 'model_not_loaded'},
    });
  });

  it('says it is working while the model loads', async () => {
    const {upstream, chat} = setup();
    upstream.seed('c1', [
      upstream.user('Q', 'u1'),
      upstream.turn([{content: 'A'}], {}, 'a1'),
    ]);
    upstream.open('c1');
    let release: (value: 'ready') => void = () => {};
    upstream.ensureModel = () =>
      new Promise(resolve => {
        release = resolve;
      });
    const {events} = record(chat, 'c1');

    const sending = chat.send('c1', {text: 'Again'});
    await settle();
    expect(chat.phase('c1')).toBe('working');
    expect(events).toContainEqual(
      expect.objectContaining({
        type: 'phase',
        phase: 'working',
        label: 'loading_model',
      }),
    );
    release('ready');
    await sending;
    expect(chat.phase('c1')).toBe('writing');
  });
});

describe('UpstreamChat: stop, interrupt, regenerate, edit, versions', () => {
  it('marks a stopped answer and keeps its text', async () => {
    const {upstream, chat} = setup();
    const result = await chat.send(null, {text: 'Long one'});
    const {events} = record(chat, result.conversationId);
    upstream.token({content: 'Part of the'});

    chat.stop(result.conversationId);
    await settle();

    const answer = chat.messages(result.conversationId)[1];
    expect(answer.status).toBe('stopped');
    expect(answer.text).toBe('Part of the');
    expect(events[events.length - 1]).toEqual({
      type: 'finished',
      messageId: result.assistantMessageId,
      status: 'stopped',
    });
    const stored = upstream
      .messagesOf(result.conversationId)!
      .find(row => row.id === result.assistantMessageId);
    expect(stored?.metadata?.[META.stopped]).toBe(true);
  });

  it('does not call an answer stopped when it had already ended', async () => {
    const {upstream, chat} = setup();
    const first = await chat.send(null, {text: 'One'});
    upstream.token({content: 'Done'});
    upstream.finish();
    await settle();
    await chat.send(first.conversationId, {text: 'Two'});

    expect(chat.messages(first.conversationId)[1].status).toBe('complete');
  });

  it('interrupts: stops the answer first, then sends the new message', async () => {
    const {upstream, chat} = setup();
    const first = await chat.send(null, {text: 'One'});
    upstream.token({content: 'Half'});
    upstream.calls.length = 0;

    const second = await chat.send(first.conversationId, {text: 'Two'});

    expect(upstream.calls.filter(c => !c.startsWith('metadata'))).toEqual([
      'stop',
      'ensureModel',
      'thinking:false',
      'send:Two',
    ]);
    // The stop was recorded before the new message went out.
    expect(
      upstream.calls.findIndex(c => c.startsWith('metadata')),
    ).toBeLessThan(upstream.calls.indexOf('send:Two'));
    expect(
      chat.messages(second.conversationId).map(m => [m.role, m.status, m.text]),
    ).toEqual([
      ['user', 'complete', 'One'],
      ['assistant', 'stopped', 'Half'],
      ['user', 'complete', 'Two'],
      ['assistant', 'pending', ''],
    ]);
  });

  it('regenerate removes the question and asks it again', async () => {
    const {upstream, chat} = setup();
    upstream.seed('c1', [
      upstream.user('Earlier', 'u0'),
      upstream.turn([{content: 'Earlier answer'}], {}, 'a0'),
      upstream.user('The question', 'u1'),
      upstream.turn([{content: 'Old answer'}], {}, 'a1'),
    ]);
    upstream.open('c1');
    const {events} = record(chat, 'c1');

    const result = await chat.regenerate('c1', 'a1', {thinking: true});

    expect(upstream.calls).toEqual([
      'remove:u1:true',
      'ensureModel',
      'thinking:true',
      'send:The question',
    ]);
    expect(types(events)).toEqual(
      expect.arrayContaining(['message_removed', 'message_added']),
    );
    expect(
      events
        .filter(event => event.type === 'message_removed')
        .map(event => (event as {messageId: string}).messageId)
        .sort(),
    ).toEqual(['a1', 'u1']);
    const views = chat.messages('c1');
    expect(views.map(m => m.text)).toEqual([
      'Earlier',
      'Earlier answer',
      'The question',
      '',
    ]);
    expect(result.assistantMessageId).toBe(views[3].id);
    await expect(chat.regenerate('c1', 'nope')).rejects.toThrow();
  });

  it('edit removes the old question and sends the new text', async () => {
    const {upstream, chat} = setup();
    upstream.seed('c1', [
      upstream.user('Typo qestion', 'u1'),
      upstream.turn([{content: 'Answer'}], {}, 'a1'),
    ]);
    upstream.open('c1');

    const result = await chat.edit('c1', 'u1', {text: 'Typo question'});

    expect(upstream.calls).toEqual([
      'remove:u1:true',
      'ensureModel',
      'thinking:false',
      'send:Typo question',
    ]);
    expect(chat.messages('c1').map(m => m.text)).toEqual(['Typo question', '']);
    expect(result.userMessageId).toBe(chat.messages('c1')[0].id);
    await expect(chat.edit('c1', 'a1', {text: 'x'})).rejects.toThrow();
  });

  it('switching versions stops a running answer first', async () => {
    const {upstream, chat} = setup();
    const result = await chat.send(null, {text: 'Q'});
    upstream.token({content: 'A'});
    upstream.calls.length = 0;

    await chat.switchVersion(
      result.conversationId,
      result.assistantMessageId,
      0,
    );
    const order = upstream.calls.filter(c => !c.startsWith('metadata'));
    expect(order).toEqual([
      'stop',
      `switch:${result.conversationId}:${result.assistantMessageId}:0`,
    ]);
  });

  it('runs commands one after the other', async () => {
    const {upstream, chat} = setup();
    const both = Promise.all([
      chat.send(null, {text: 'First'}),
      chat.send(null, {text: 'Second'}),
    ]);
    const [first, second] = await both;
    // Each `null` starts a chat of its own; the second waited for the first.
    expect(first.conversationId).not.toBe(second.conversationId);
    expect(upstream.calls.indexOf('send:First')).toBeLessThan(
      upstream.calls.indexOf('activate:null'),
    );
    expect(upstream.calls.filter(c => c.startsWith('send:'))).toEqual([
      'send:First',
      'send:Second',
    ]);
  });

  it('stores feedback on the answer', async () => {
    const {upstream, chat} = setup();
    upstream.seed('c1', [
      upstream.user('Q', 'u1'),
      upstream.turn([{content: 'A'}], {}, 'a1'),
    ]);
    upstream.open('c1');
    const {events} = record(chat, 'c1');

    await chat.setFeedback('c1', 'a1', 'up');
    expect(chat.messages('c1')[1].feedback).toBe('up');
    expect(events).toContainEqual(
      expect.objectContaining({type: 'message_updated'}),
    );
    await chat.setFeedback('c1', 'a1', null);
    expect(chat.messages('c1')[1].feedback).toBeUndefined();
  });
});

describe('UpstreamChat: follow-ups and starters', () => {
  it('shows follow-ups for the open chat until something else is sent', async () => {
    const {upstream, chat} = setup();
    const result = await chat.send(null, {text: 'Q'});
    upstream.token({content: 'A'});
    // Suggestions that arrive while an answer is still running are stale.
    upstream.emitFollowUps(result.conversationId, ['Too early']);
    expect(chat.followUps(result.conversationId)).toEqual([]);
    upstream.finish();
    await settle();

    const notified = jest.fn();
    chat.subscribe(notified);
    upstream.emitFollowUps('another-chat', ['Not mine']);
    expect(chat.followUps(result.conversationId)).toEqual([]);
    upstream.emitFollowUps(result.conversationId, ['More?', 'Example?']);
    expect(chat.followUps(result.conversationId)).toEqual([
      'More?',
      'Example?',
    ]);
    expect(notified).toHaveBeenCalled();

    await chat.send(result.conversationId, {text: 'More?'});
    expect(chat.followUps(result.conversationId)).toEqual([]);
  });

  it('drops follow-ups when another chat is opened', async () => {
    const {upstream, chat} = setup();
    const result = await chat.send(null, {text: 'Q'});
    upstream.token({content: 'A'});
    upstream.finish();
    await settle();
    upstream.emitFollowUps(result.conversationId, ['More?']);

    upstream.open(null);
    expect(chat.followUps(result.conversationId)).toEqual([]);
  });

  it('serves starters from the engine', () => {
    const {chat} = setup();
    expect(chat.starters(3)).toHaveLength(3);
    expect(chat.starters()).toHaveLength(4);
  });
});
