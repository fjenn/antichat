import '../../../testing/setup';

import {createFakePorts, type FakePorts} from '../../../contracts/fakes';
import {ThreadController} from '../thread/ThreadController';

const mockStreams: Array<{
  text: string;
  ended: boolean;
  disposed: boolean;
}> = [];
const streams = mockStreams;

jest.mock('react-native-enriched-markdown', () => ({
  createMarkdownStream: () => {
    const state = {text: '', ended: false, disposed: false};
    mockStreams.push(state);
    return {
      append: (chunk: string) => {
        state.text += chunk;
      },
      getText: () => state.text,
      end: () => {
        state.ended = true;
      },
      reset: (text = '') => {
        state.text = text;
        state.ended = false;
      },
      dispose: () => {
        state.disposed = true;
      },
    };
  },
}));

jest.useFakeTimers();

function setup(tokensPerSecond = 1000) {
  const ports: FakePorts = createFakePorts({
    chat: {tokensPerSecond, firstTokenMs: 10},
  });
  return ports;
}

async function start(ports: FakePorts, text: string) {
  const sent = await ports.chat.send(null, {text});
  const controller = new ThreadController(ports.chat, sent.conversationId);
  controller.attach();
  return {sent, controller};
}

const frames = (ms: number) => {
  // Timers drive the fake model; animation frames drive the batcher.
  jest.advanceTimersByTime(ms);
};

describe('ThreadController', () => {
  beforeEach(() => {
    streams.length = 0;
    (global as any).requestAnimationFrame = (callback: () => void) =>
      setTimeout(callback, 16);
  });

  it('adopts an answer that is already running and streams it natively', async () => {
    const ports = setup();
    const {controller, sent} = await start(ports, 'Write a birthday message');
    const first = controller.getSnapshot();
    expect(first.rows.map(row => row.message.role)).toEqual([
      'user',
      'assistant',
    ]);
    expect(first.rows[1].live).toBe(true);
    expect(first.generating).toBe(true);

    frames(5000);
    const done = controller.getSnapshot();
    expect(done.generating).toBe(false);
    expect(done.rows[1].live).toBe(false);
    expect(done.rows[1].message.status).toBe('complete');
    const final = ports.chat
      .messages(sent.conversationId)
      .find(message => message.id === sent.assistantMessageId)!;
    expect(streams[0].text.trim()).toBe(final.text.trim());
    expect(streams[0].ended).toBe(true);
    controller.dispose();
  });

  it('does not rebuild rows for tokens', async () => {
    const ports = setup(200);
    const {controller} = await start(ports, 'Explain transformers');
    frames(200);
    let notified = 0;
    controller.subscribe(() => {
      notified += 1;
    });
    const before = controller.getSnapshot().rows;
    frames(300);
    expect(streams[0].text.length).toBeGreaterThan(20);
    expect(controller.getSnapshot().rows).toBe(before);
    expect(notified).toBe(0);
    controller.dispose();
  });

  it('counts a turn and names the question to pin when a message is sent', async () => {
    const ports = setup();
    const {controller, sent} = await start(ports, 'First');
    frames(5000);
    const turnBefore = controller.getSnapshot().turn;
    const next = await ports.chat.send(sent.conversationId, {text: 'Second'});
    const snapshot = controller.getSnapshot();
    expect(snapshot.turn).toBe(turnBefore + 1);
    expect(snapshot.turnAnchorKey).toBe(next.userMessageId);
    expect(snapshot.rows[snapshot.rows.length - 1].live).toBe(true);
    controller.dispose();
  });

  it('keeps rows of finished messages identical across a new turn', async () => {
    const ports = setup();
    const {controller, sent} = await start(ports, 'First');
    frames(5000);
    const rows = controller.getSnapshot().rows;
    await ports.chat.send(sent.conversationId, {text: 'Second'});
    frames(5000);
    // Busy came and went, so the same row objects are back.
    expect(controller.getSnapshot().rows[0].message).toBe(rows[0].message);
    expect(controller.getSnapshot().rows.slice(0, 1)).toEqual(rows.slice(0, 1));
    controller.dispose();
  });

  it('marks every row busy while an answer runs, and free after', async () => {
    const ports = setup();
    const {controller} = await start(ports, 'First');
    expect(controller.getSnapshot().rows.every(row => row.busy)).toBe(true);
    frames(5000);
    expect(controller.getSnapshot().rows.some(row => row.busy)).toBe(false);
    controller.dispose();
  });

  it('keeps the partial answer when stopped', async () => {
    const ports = setup(50);
    const {controller, sent} = await start(ports, 'Explain transformers');
    frames(600);
    ports.chat.stop(sent.conversationId);
    frames(50);
    const row = controller.getSnapshot().rows[1];
    expect(row.message.status).toBe('stopped');
    expect(row.live).toBe(false);
    expect(row.message.text.length).toBeGreaterThan(0);
    expect(streams[0].ended).toBe(true);
    controller.dispose();
  });

  it('shows versions after a regenerate and follows a switch', async () => {
    const ports = setup();
    const {controller, sent} = await start(ports, 'First');
    frames(5000);
    await ports.chat.regenerate(sent.conversationId, sent.assistantMessageId);
    frames(5000);
    let answer = controller.getSnapshot().rows[1];
    expect(answer.message.version).toEqual({index: 1, count: 2});
    await ports.chat.switchVersion(sent.conversationId, answer.message.id, 0);
    answer = controller.getSnapshot().rows[1];
    expect(answer.message.version).toEqual({index: 0, count: 2});
    expect(answer.message.id).toBe(sent.assistantMessageId);
    controller.dispose();
  });

  it('offers follow-ups on the newest answer only, and not while writing', async () => {
    const ports = setup();
    const {controller, sent} = await start(ports, 'First');
    expect(controller.getSnapshot().followUps).toHaveLength(0);
    frames(5000);
    const rows = controller.getSnapshot().rows;
    expect(rows[1].followUps.length).toBeGreaterThan(0);
    expect(rows[0].followUps).toHaveLength(0);
    await ports.chat.send(sent.conversationId, {text: 'Second'});
    expect(
      controller.getSnapshot().rows.every(row => row.followUps.length === 0),
    ).toBe(true);
    controller.dispose();
  });

  it('carries an error to the row', async () => {
    const ports = setup();
    ports.chat.failNext({code: 'out_of_memory', retryable: true});
    const {controller} = await start(ports, 'First');
    frames(5000);
    const row = controller.getSnapshot().rows[1];
    expect(row.message.status).toBe('error');
    expect(row.message.error?.code).toBe('out_of_memory');
    controller.dispose();
  });

  it('collects thinking text for the sheet while it arrives', async () => {
    const ports = setup(200);
    const sent = await ports.chat.send(null, {text: 'Think', thinking: true});
    const controller = new ThreadController(ports.chat, sent.conversationId);
    controller.attach();
    let heard = 0;
    controller.subscribeReasoning(() => {
      heard += 1;
    });
    frames(60);
    expect(heard).toBeGreaterThan(0);
    expect(
      controller.reasoningOf(sent.assistantMessageId).length,
    ).toBeGreaterThan(0);
    expect(controller.getSnapshot().rows[1].phase).toBe('thinking');
    frames(8000);
    expect(
      controller.getSnapshot().rows[1].message.reasoning?.durationMs,
    ).toBeDefined();
    controller.dispose();
  });

  it('can be attached again after it was disposed', async () => {
    const ports = setup();
    const {controller, sent} = await start(ports, 'First');
    frames(5000);
    controller.dispose();
    controller.attach();
    await ports.chat.send(sent.conversationId, {text: 'Second'});
    expect(controller.getSnapshot().rows).toHaveLength(4);
    controller.dispose();
  });
});
