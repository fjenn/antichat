import '../../../testing/setup';

import React from 'react';
import {
  act,
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from '@testing-library/react-native';

import {setPorts} from '../../../adapters';
import {createFakePorts, type FakePorts} from '../../../contracts/fakes';
import {createMemoryEngine} from '../../../engine/memory/engine';
import {
  createChatHarness,
  type ChatHarness,
} from '../../../engine/memory/__tests__/support/memoryHarness';
import {toast} from '../../primitives';
import {
  MemoryScreen,
  MemorySettingsRows,
  MemoryUpdatedNotice,
  MemoryUsedChip,
  createFakeMemoryUi,
  filterMemories,
  getMemoryUi,
  registerMemoryUi,
  setMemoryUi,
  type FakeMemoryUi,
} from '..';

const navigation = {goBack: jest.fn(), navigate: jest.fn()};

describe('memory screens on the fake', () => {
  let ports: FakePorts;
  let memory: FakeMemoryUi;

  beforeEach(() => {
    jest.clearAllMocks();
    ports = createFakePorts();
    setPorts(ports);
    memory = createFakeMemoryUi(ports.memory);
    setMemoryUi(memory);
  });

  afterEach(() => {
    cleanup();
    setMemoryUi();
    setPorts();
    toast.hide();
  });

  it('filters by every word of the query', () => {
    const rows = ports.memory.memories.map(item => ({
      ...item,
      pinned: false,
      projectId: null,
      conversationId: null,
    }));
    expect(filterMemories(rows, 'SHORT answers').map(row => row.text)).toEqual([
      'Prefers short answers with examples',
    ]);
    expect(filterMemories(rows, '  ')).toHaveLength(rows.length);
  });

  it('lists, searches, edits and deletes memories', async () => {
    render(<MemoryScreen navigation={navigation} />);
    expect(await screen.findByText('Is vegetarian')).toBeTruthy();
    expect(screen.getByText('4 memories')).toBeTruthy();

    fireEvent.changeText(screen.getByTestId('memory-search'), 'designer');
    expect(screen.queryByText('Is vegetarian')).toBeNull();
    expect(screen.getByText('Works as a product designer')).toBeTruthy();
    fireEvent.changeText(screen.getByTestId('memory-search'), 'zzz');
    expect(screen.getByTestId('memory-no-results')).toBeTruthy();
    fireEvent.changeText(screen.getByTestId('memory-search'), '');

    fireEvent.press(screen.getByTestId('memory-row-mem1'));
    fireEvent.changeText(
      await screen.findByTestId('memory-editor-text'),
      'Is vegan',
    );
    fireEvent.press(screen.getByTestId('memory-editor-save'));
    expect(await screen.findByText('Is vegan')).toBeTruthy();
    expect(ports.memory.memories.find(m => m.id === 'mem1')?.text).toBe(
      'Is vegan',
    );

    await act(async () => {
      fireEvent.press(screen.getByTestId('memory-delete-mem2'));
    });
    await waitFor(() => expect(ports.memory.memories).toHaveLength(3));
    await waitFor(() =>
      expect(screen.queryByText('Works as a product designer')).toBeNull(),
    );
  });

  it('adds a memory and reports a duplicate', async () => {
    render(<MemoryScreen navigation={navigation} />);
    await screen.findByText('Is vegetarian');
    fireEvent.press(screen.getByTestId('memory-add'));
    fireEvent.changeText(
      await screen.findByTestId('memory-editor-text'),
      'Lives in Porto',
    );
    fireEvent.press(screen.getByTestId('memory-editor-save'));
    expect(await screen.findByText('Lives in Porto')).toBeTruthy();

    fireEvent.press(screen.getByTestId('memory-add'));
    fireEvent.changeText(
      await screen.findByTestId('memory-editor-text'),
      'lives in porto',
    );
    fireEvent.press(screen.getByTestId('memory-editor-save'));
    await waitFor(() =>
      expect(toast.current()?.message).toBe('Already remembered'),
    );
    expect(ports.memory.memories).toHaveLength(5);
  });

  it('deletes everything after a confirmation', async () => {
    render(<MemoryScreen navigation={navigation} />);
    await screen.findByText('Is vegetarian');
    fireEvent.press(screen.getByTestId('memory-delete-all'));
    expect(ports.memory.memories).toHaveLength(4);
    fireEvent.press(await screen.findByTestId('memory-confirm-delete-all-yes'));
    expect(await screen.findByTestId('memory-empty')).toBeTruthy();
    expect(ports.memory.memories).toHaveLength(0);
  });

  it('pauses memory, and offers to turn it on when it is off', async () => {
    render(<MemoryScreen navigation={navigation} />);
    await screen.findByText('Is vegetarian');
    fireEvent.press(screen.getByTestId('memory-pause'));
    await waitFor(() => expect(memory.state().paused).toBe(true));

    await act(() => memory.setEnabled(false));
    expect(screen.getByTestId('memory-off')).toBeTruthy();
    fireEvent.press(screen.getByTestId('memory-turn-on'));
    await waitFor(() => expect(ports.memory.enabled).toBe(true));
  });

  it('shows "Memory updated" for the chat it happened in, with undo', async () => {
    const onManage = jest.fn();
    render(<MemoryUpdatedNotice conversationId="c1" onManage={onManage} />);
    expect(screen.queryByTestId('memory-updated')).toBeNull();

    await act(() => memory.noteSaved('c2', 'Has a dog called Bo'));
    expect(screen.queryByTestId('memory-updated')).toBeNull();
    await act(() => memory.noteSaved('c1', 'Is learning Portuguese'));
    fireEvent.press(screen.getByTestId('memory-updated'));
    expect(await screen.findByText('Is learning Portuguese')).toBeTruthy();

    fireEvent.press(screen.getByTestId('memory-updated-manage'));
    expect(onManage).toHaveBeenCalled();

    const saved = memory.changes('c1')[0];
    await act(() => memory.undoChange(saved));
    expect(screen.queryByTestId('memory-updated')).toBeNull();
    expect(
      ports.memory.memories.some(m => m.text === 'Is learning Portuguese'),
    ).toBe(false);
  });

  it('shows the "memory used" chip only on answers that used memory', async () => {
    ports.memory.markUsed('a1', ['mem1', 'mem3']);
    render(
      <>
        <MemoryUsedChip messageId="a1" />
        <MemoryUsedChip messageId="a2" testID="other" />
      </>,
    );
    fireEvent.press(await screen.findByTestId('memory-used'));
    expect(await screen.findByText('Is vegetarian')).toBeTruthy();
    expect(
      screen.getByText('Prefers short answers with examples'),
    ).toBeTruthy();
    expect(screen.queryByTestId('other')).toBeNull();
  });

  it('has the settings rows: switch, past chats, manage', async () => {
    const onManage = jest.fn();
    render(<MemorySettingsRows onManage={onManage} />);
    fireEvent.press(screen.getByTestId('memory-enabled'));
    await waitFor(() => expect(ports.memory.enabled).toBe(false));
    fireEvent.press(screen.getByTestId('memory-manage'));
    expect(onManage).toHaveBeenCalled();
  });
});

describe('memory screens on the engine', () => {
  let h: ChatHarness;
  let unregister: () => void;
  let engine: ReturnType<typeof createMemoryEngine>;

  beforeEach(async () => {
    h = await createChatHarness();
    engine = createMemoryEngine({
      db: h.db,
      chats: h.chats.store,
      now: () => h.clock.now,
    });
    await engine.init();
    unregister = registerMemoryUi({engine});
  });

  afterEach(() => {
    cleanup();
    unregister();
    h.close();
  });

  it('adds, edits, pauses and deletes through the engine port', async () => {
    const ui = getMemoryUi();
    const changed = jest.fn();
    ui.subscribe(changed);
    expect(await ui.add('I am vegetarian')).toBe('added');
    expect(await ui.add('I am vegetarian')).toBe('duplicate');
    let rows = await ui.list();
    expect(rows).toHaveLength(1);
    expect(rows[0].origin).toBe('saved');
    expect(changed).toHaveBeenCalled();

    await ui.edit(rows[0].id, 'I am vegan');
    rows = await ui.list();
    expect(rows[0].text).toBe('I am vegan');

    await ui.setPaused(true);
    expect(ui.state()).toMatchObject({enabled: true, paused: true});
    expect(engine.store.getSettings().paused).toBe(true);
    await ui.setPaused(false);
    await ui.setEnabled(false);
    expect(engine.store.getSettings().enabled).toBe(false);
    await ui.setEnabled(true);

    await ui.removeAll();
    expect(await ui.list()).toHaveLength(0);
  });

  it('records what a chat saved and undoes it', async () => {
    const ui = getMemoryUi();
    const chat = await h.addChat('Dinner', [
      ['Remember I am vegetarian', 'Ok'],
    ]);
    const saved = await engine.writer.save({
      text: 'User is vegetarian.',
      origin: 'tool',
      explicit: true,
      fresh: true,
      sessionId: chat,
    });
    expect(saved.status).toBe('added');
    expect(ui.changes(chat)).toEqual([
      expect.objectContaining({kind: 'saved', text: 'User is vegetarian.'}),
    ]);
    expect(ui.changes('another')).toHaveLength(0);

    await ui.undoChange(ui.changes(chat)[0]);
    expect(ui.changes(chat)).toHaveLength(0);
    expect(await ui.list()).toHaveLength(0);
  });

  it('lists the memories an answer used, cited ones marked', async () => {
    const ui = getMemoryUi();
    const chat = await h.addChat('Dinner', [
      ['Dinner idea?', 'Veggie stir-fry'],
    ]);
    await ui.add('I am vegetarian');
    await ui.add('I live in Porto');
    const [a, b] = await engine.store.list();
    const useId = await engine.store.recordUse(chat, [
      {memoryId: a.id, how: 'always'},
      {memoryId: b.id, how: 'always'},
    ]);
    await engine.store.confirmUse(useId!, {messageId: 'm9', citedIds: [a.id]});

    const used = await ui.usedBy('m9');
    expect(used).toHaveLength(2);
    expect(used.filter(item => item.cited).map(item => item.memoryId)).toEqual([
      a.id,
    ]);
    expect(await ui.usedBy('unknown')).toEqual([]);

    render(<MemoryUsedChip messageId="m9" />);
    fireEvent.press(await screen.findByTestId('memory-used'));
    expect(
      await screen.findByText('Also available to this answer'),
    ).toBeTruthy();
  });
});
