import type {ConversationPort as StorePort} from '../../engine/store/port';
import type {
  HistoryItem,
  HistoryListing,
  SearchHit,
} from '../../engine/store/types';
import {
  StoreConversations,
  flattenSegments,
  type SessionGateway,
  type UpstreamChat,
} from '../conversationPort';

const NOW = new Date(2026, 10, 24, 12, 0, 0).getTime();
const HOUR = 60 * 60 * 1000;

function item(
  sessionId: string,
  fields: Partial<HistoryItem> = {},
): HistoryItem {
  return {
    sessionId,
    title: `Title ${sessionId}`,
    createdAt: NOW - 5 * HOUR,
    updatedAt: NOW - HOUR,
    pinned: false,
    archived: false,
    locked: false,
    projectId: null,
    originKind: null,
    originSessionId: null,
    ...fields,
  };
}

function setup(initial: HistoryItem[] = []) {
  let items = initial;
  const listeners = new Set<() => void>();
  const upstreamChats = new Map<string, UpstreamChat>();
  let created = 0;
  const listing = (): HistoryListing => ({
    pinned: items.filter(entry => entry.pinned),
    groups: [
      {
        key: 'today',
        label: 'Today',
        items: items.filter(entry => !entry.pinned),
      },
    ],
  });
  const store = {
    subscribe: jest.fn((listener: () => void) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    }),
    listHistory: jest.fn(async () => listing()),
    search: jest.fn(async (): Promise<SearchHit[]> => []),
    rename: jest.fn(async (id: string, title: string) => {
      items = items.map(entry =>
        entry.sessionId === id ? {...entry, title} : entry,
      );
    }),
    setPinned: jest.fn(async (id: string, pinned: boolean) => {
      items = items.map(entry =>
        entry.sessionId === id ? {...entry, pinned} : entry,
      );
    }),
    setArchived: jest.fn(async (id: string, archived: boolean) => {
      items = items.map(entry =>
        entry.sessionId === id ? {...entry, archived} : entry,
      );
    }),
    setLocked: jest.fn(async () => {}),
    setProject: jest.fn(async () => {}),
    deleteSessions: jest.fn(async (ids: string[]) => {
      items = items.filter(entry => !ids.includes(entry.sessionId));
    }),
    branch: jest.fn(async (id: string) => {
      items = [
        item('branch-1', {
          title: 'Branch · Title',
          originKind: 'branch',
          originSessionId: id,
          updatedAt: NOW,
        }),
        ...items,
      ];
      return 'branch-1';
    }),
    startTemporaryChat: jest.fn(),
    cancelTemporaryChat: jest.fn(),
    keepTemporaryChat: jest.fn(async (id: string) => {
      items = [item(id, {title: 'Kept', updatedAt: NOW}), ...items];
    }),
    discardTemporaryChat: jest.fn(async () => {}),
  };
  const sessions: SessionGateway = {
    createSession: jest.fn(async () => {
      const id = `new-${++created}`;
      upstreamChats.set(id, {
        id,
        title: 'New Session',
        createdAt: NOW,
        pinned: false,
      });
      return id;
    }),
    find: id => upstreamChats.get(id),
  };
  const port = new StoreConversations({
    store: store as unknown as StorePort,
    sessions,
    now: () => NOW,
  });
  return {
    port,
    store,
    sessions,
    upstreamChats,
    set(next: HistoryItem[]) {
      items = next;
    },
    change() {
      listeners.forEach(listener => listener());
    },
    flush: async () => {
      await port.refresh();
      await port.refresh();
    },
  };
}

describe('StoreConversations', () => {
  it('lists saved chats newest first and keeps archived ones apart', async () => {
    const t = setup([
      item('old', {updatedAt: NOW - 3 * HOUR}),
      item('new', {updatedAt: NOW - HOUR}),
      item('pin', {pinned: true, updatedAt: NOW - 30 * HOUR}),
      item('arch', {archived: true}),
      item('untitled', {title: 'New Session', updatedAt: NOW - 2 * HOUR}),
    ]);
    await t.flush();

    expect(t.port.conversations.map(c => c.id)).toEqual([
      'new',
      'untitled',
      'old',
      'pin',
    ]);
    expect(t.port.archived().map(c => c.id)).toEqual(['arch']);
    expect(t.port.get('arch')?.archived).toBe(true);
    // Upstream's placeholder is not a title.
    expect(t.port.get('untitled')?.title).toBe('');
    expect(
      t.port.sections(NOW).map(s => [s.key, s.conversations.length]),
    ).toEqual([
      ['pinned', 1],
      ['today', 3],
    ]);
    expect(t.store.listHistory).toHaveBeenCalledWith(
      expect.objectContaining({scope: 'all'}),
    );
  });

  it('tells listeners only when the list really changed', async () => {
    const t = setup([item('a'), item('b', {updatedAt: NOW - 2 * HOUR})]);
    await t.flush();
    const listener = jest.fn();
    t.port.subscribe(listener);
    const before = t.port.conversations;
    const a = t.port.get('a');

    t.change();
    await t.flush();
    expect(listener).not.toHaveBeenCalled();
    expect(t.port.conversations).toBe(before);

    t.set([
      item('a'),
      item('b', {updatedAt: NOW - 2 * HOUR, title: 'A real title'}),
    ]);
    t.change();
    await t.flush();
    expect(listener).toHaveBeenCalledTimes(1);
    expect(t.port.get('b')?.title).toBe('A real title');
    // The untouched chat keeps its object.
    expect(t.port.get('a')).toBe(a);
  });

  it('serves a chat upstream has and the store has not listed yet', async () => {
    const t = setup();
    await t.flush();
    t.upstreamChats.set('fresh', {
      id: 'fresh',
      title: 'New Session',
      createdAt: NOW,
      pinned: false,
    });
    const first = t.port.get('fresh');
    expect(first).toMatchObject({id: 'fresh', title: '', archived: false});
    expect(t.port.get('fresh')).toBe(first);
    expect(t.port.get('unknown')).toBeUndefined();
  });

  it('renames, pins, archives and deletes through the store', async () => {
    const t = setup([item('a'), item('b')]);
    await t.flush();

    await t.port.rename('a', '  Trimmed  ');
    expect(t.store.rename).toHaveBeenCalledWith('a', 'Trimmed');
    expect(t.port.get('a')?.title).toBe('Trimmed');

    await t.port.setPinned('a', true);
    expect(t.port.get('a')?.pinned).toBe(true);

    await t.port.setArchived('b', true);
    expect(t.port.conversations.map(c => c.id)).toEqual(['a']);

    await t.port.remove('a');
    expect(t.store.deleteSessions).toHaveBeenCalledWith(['a']);
    expect(t.port.get('a')).toBeUndefined();

    await t.port.removeAll();
    expect(t.store.deleteSessions).toHaveBeenLastCalledWith(['b']);
    expect(t.port.archived()).toEqual([]);
  });

  it('creates a temporary chat that never joins the list', async () => {
    const t = setup();
    await t.flush();
    const chat = await t.port.create({temporary: true});

    expect(t.store.startTemporaryChat).toHaveBeenCalled();
    expect(chat.temporary).toBe(true);
    expect(t.port.get(chat.id)).toBe(chat);
    expect(t.port.conversations).toEqual([]);

    await t.port.saveTemporary(chat.id);
    expect(t.store.keepTemporaryChat).toHaveBeenCalledWith(chat.id);
    expect(t.port.get(chat.id)).toMatchObject({
      temporary: false,
      title: 'Kept',
    });

    const other = await t.port.create({temporary: true});
    await t.port.remove(other.id);
    expect(t.store.discardTemporaryChat).toHaveBeenCalledWith(other.id);
    expect(t.port.get(other.id)?.temporary).not.toBe(true);
  });

  it('takes the temporary flag back when the chat cannot be created', async () => {
    const t = setup();
    (t.sessions.createSession as jest.Mock).mockResolvedValueOnce(null);
    await expect(t.port.create({temporary: true})).rejects.toThrow();
    expect(t.store.cancelTemporaryChat).toHaveBeenCalled();
  });

  it('branches and returns the new chat with where it came from', async () => {
    const t = setup([item('a')]);
    await t.flush();
    const branch = await t.port.branch('a', 'm7');

    expect(t.store.branch).toHaveBeenCalledWith('a', 'm7');
    expect(branch).toMatchObject({
      id: 'branch-1',
      branchedFrom: {conversationId: 'a', messageId: 'm7'},
    });
    expect(t.port.conversations[0].id).toBe('branch-1');
  });

  it('maps search hits to snippet text and match ranges', async () => {
    const t = setup([item('a')]);
    await t.flush();
    t.store.search.mockResolvedValueOnce([
      {
        sessionId: 'a',
        title: 'Title a',
        titleSegments: [{text: 'Title a', match: false}],
        titleMatched: false,
        snippet: {
          nodeId: 'n1',
          messageId: 'm1',
          role: 'assistant',
          onActivePath: true,
          segments: [
            {text: 'the ', match: false},
            {text: 'tide', match: true},
            {text: ' comes in', match: false},
          ],
        },
        messageMatches: 1,
        score: -1,
        updatedAt: NOW,
        archived: false,
        locked: false,
      },
      {
        sessionId: 'gone',
        title: 'Tide tables',
        titleSegments: [
          {text: 'Tide', match: true},
          {text: ' tables', match: false},
        ],
        titleMatched: true,
        snippet: null,
        messageMatches: 0,
        score: -2,
        updatedAt: NOW,
        archived: true,
        locked: false,
      },
    ]);

    const hits = await t.port.search('tide', {limit: 5});
    expect(t.store.search).toHaveBeenCalledWith('tide', {limit: 5});
    expect(hits[0]).toEqual({
      conversation: t.port.get('a'),
      messageId: 'm1',
      snippet: 'the tide comes in',
      matches: [[4, 8]],
    });
    expect(hits[1]).toMatchObject({
      conversation: {id: 'gone', title: 'Tide tables', archived: true},
      matches: [[0, 4]],
    });
    expect(hits[1].snippet).toBeUndefined();

    expect(await t.port.search('   ')).toEqual([]);
    expect(await t.port.search('tide', {filter: 'images'})).toEqual([]);
  });

  it('flattens highlighted runs', () => {
    expect(
      flattenSegments([
        {text: 'ab', match: true},
        {text: 'cd', match: false},
        {text: 'ef', match: true},
      ]),
    ).toEqual({
      text: 'abcdef',
      matches: [
        [0, 2],
        [4, 6],
      ],
    });
  });
});
