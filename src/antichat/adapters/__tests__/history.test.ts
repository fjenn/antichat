import {
  createHarness,
  type Harness,
} from '../../engine/store/__tests__/support/harness';
import {listHistory} from '../../engine/store/history';
import type {ConversationPort as StorePort} from '../../engine/store/port';
import {searchConversations} from '../../engine/store/search';
import {
  exportConversations,
  exportSessionMarkdown,
} from '../../engine/store/transfer';
import {
  StoreHistory,
  exportFileName,
  flattenSegments,
  isHistoryPort,
  threadAsPlainText,
} from '../history';
import {FakeConversations} from '../../contracts/fakes';

/** M3's port over the Jest harness (Node SQLite, in-memory upstream). */
function storePort(h: Harness): StorePort & {pending: boolean} {
  const unsupported = async (): Promise<never> => {
    throw new Error('not used by the history adapter');
  };
  const port = {
    pending: false,
    ready: async () => {},
    subscribe: (listener: () => void) => h.store.onChange(listener),
    listHistory: (options?: Parameters<typeof listHistory>[1]) =>
      listHistory(h.db, {now: h.up.clock, ...options}),
    search: (
      query: string,
      options?: Parameters<typeof searchConversations>[2],
    ) => searchConversations(h.db, query, options),
    getMeta: (id: string) => h.store.getMeta(id),
    getThread: async (id: string) => {
      await h.store.syncSession(id);
      return h.store.getThread(id);
    },
    switchVersion: unsupported,
    showNode: unsupported,
    branch: (id: string, messageId: string) => h.store.branch(id, messageId),
    rename: (id: string, title: string) => h.store.rename(id, title),
    setPinned: (id: string, pinned: boolean) => h.store.setPinned(id, pinned),
    setArchived: (id: string, archived: boolean) =>
      h.store.setArchived(id, archived),
    setLocked: (id: string, locked: boolean) => h.store.setLocked(id, locked),
    setProject: (id: string, project: string | null) =>
      h.store.setProject(id, project),
    deleteSessions: (ids: string[]) => h.store.deleteSessions(ids),
    startTemporaryChat() {
      port.pending = true;
    },
    cancelTemporaryChat() {
      port.pending = false;
    },
    isTemporaryPending: () => port.pending,
    keepTemporaryChat: (id: string) => h.store.keepTemporary(id),
    discardTemporaryChat: (id: string) => h.store.discardTemporary(id),
    exportConversations: (ids?: string[]) => exportConversations(h.store, ids),
    exportArchive: unsupported,
    exportMarkdown: (
      id: string,
      options?: Parameters<typeof exportSessionMarkdown>[2],
    ) => exportSessionMarkdown(h.store, id, options),
    importConversations: unsupported,
    importArchive: unsupported,
  };
  return port as unknown as StorePort & {pending: boolean};
}

describe('history adapter on the conversation store', () => {
  let h: Harness;
  let port: ReturnType<typeof storePort>;
  let history: StoreHistory;

  async function chat(title: string, turns: [string, string][]) {
    const id = h.up.addSession(title);
    for (const [question, reply] of turns) {
      h.up.say(id, question);
      h.up.answer(id, reply);
    }
    await h.store.syncSession(id);
    return id;
  }

  beforeEach(async () => {
    h = await createHarness();
    port = storePort(h);
  });
  afterEach(() => {
    history?.dispose();
    h.close();
  });

  async function open() {
    history = new StoreHistory(port, () => h.up.clock);
    await history.ready();
    return history;
  }

  it('reads the listing once and serves it synchronously, newest first', async () => {
    const lisbon = await chat('Trip to Lisbon', [
      ['Where to stay?', 'Alfama.'],
    ]);
    const bread = await chat('Sourdough', [['How long?', 'A week.']]);
    history = new StoreHistory(port, () => h.up.clock);
    expect(history.loaded).toBe(false);
    expect(history.conversations).toEqual([]);
    await history.ready();
    expect(history.loaded).toBe(true);
    expect(history.conversations.map(c => c.id)).toEqual([bread, lisbon]);
    expect(history.get(lisbon)?.title).toBe('Trip to Lisbon');
    expect(history.sections()[0].key).toBe('today');
    expect(isHistoryPort(history)).toBe(true);
    expect(isHistoryPort(new FakeConversations())).toBe(false);
  });

  it('follows what the store writes by itself', async () => {
    await open();
    const seen = jest.fn();
    history.subscribe(seen);
    const id = await chat('Written elsewhere', [['Q', 'A']]);
    await history.refresh();
    expect(history.get(id)?.title).toBe('Written elsewhere');
    expect(seen).toHaveBeenCalled();
  });

  it('shows the user’s own action at once and keeps it', async () => {
    const id = await chat('Old name', [['Q', 'A']]);
    await open();

    const renamed = history.rename(id, '  New   name ');
    expect(history.get(id)?.title).toBe('New name');
    await renamed;
    expect((await h.store.getMeta(id))?.title).toBe('New name');

    const pinned = history.setPinned(id, true);
    expect(history.get(id)?.pinned).toBe(true);
    await pinned;
    expect(history.sections()[0].key).toBe('pinned');
    expect((await h.store.getMeta(id))?.pinnedAt).not.toBeNull();

    await history.rename(id, '   ');
    expect(history.get(id)?.title).toBe('New name');
  });

  it('archives a chat out of the list and finds it again', async () => {
    const id = await chat('Tax questions', [['Deadline?', 'End of July.']]);
    await open();
    await history.setPinned(id, true);

    await history.setArchived(id, true);
    expect(history.conversations).toHaveLength(0);
    expect(history.archived().map(c => c.id)).toEqual([id]);
    expect(history.get(id)?.archived).toBe(true);
    // An archived chat is not pinned any more, and search leaves it out.
    expect(history.get(id)?.pinned).toBe(false);
    expect(await history.search('tax')).toHaveLength(0);

    await history.setArchived(id, false);
    expect(history.archived()).toHaveLength(0);
    expect(history.conversations.map(c => c.id)).toEqual([id]);
    expect(await history.search('tax')).toHaveLength(1);
  });

  it('maps search hits to snippet text and highlight ranges', async () => {
    const id = await chat('Banana bread', [
      ['How ripe should the bananas be?', 'Very ripe: brown spots all over.'],
    ]);
    await chat('Something else', [['Hello', 'Hi there.']]);
    await open();

    const [byTitle] = await history.search('banana');
    expect(byTitle.conversation.id).toBe(id);
    // The title matched too: its ranges travel beside the snippet's.
    expect(byTitle.titleMatches).toEqual([[0, 6]]);
    expect(byTitle.snippet).toBeTruthy();
    for (const [start, end] of byTitle.matches) {
      expect(byTitle.snippet!.slice(start, end).toLowerCase()).toContain(
        'banana',
      );
    }

    const [byMessage] = await history.search('brown spots');
    expect(byMessage.conversation.id).toBe(id);
    expect(byMessage.messageId).toBeTruthy();
    expect(
      byMessage.matches.map(([start, end]) =>
        byMessage.snippet!.slice(start, end),
      ),
    ).toEqual(['brown', 'spots']);
    expect(await history.search('   ')).toEqual([]);
  });

  it('keeps a temporary chat out of the list and out of search', async () => {
    await open();
    await history.create({temporary: true});
    expect(port.pending).toBe(true);
    history.armTemporary(false);
    expect(port.pending).toBe(false);

    // What M3's adapter does when upstream creates the armed chat.
    const id = h.up.addSession('New Session');
    await h.store.markTemporary(id);
    h.up.say(id, 'A secret plan about zebras');
    h.up.answer(id, 'Zebras noted.');
    await h.store.syncSession(id);
    await history.refresh();

    expect(history.conversations).toHaveLength(0);
    expect(history.archived()).toHaveLength(0);
    expect(await history.search('zebras')).toHaveLength(0);
    // The open chat can still learn that it is temporary.
    expect(history.get(id)).toBeUndefined();
    await new Promise(resolve => setImmediate(resolve));
    expect(history.get(id)?.temporary).toBe(true);

    await history.discardTemporary(id);
    expect(await h.store.getMeta(id)).toBeNull();
    expect(h.up.sessions.has(id)).toBe(false);
  });

  it('turns a temporary chat into a saved one', async () => {
    await open();
    const id = h.up.addSession('New Session');
    await h.store.markTemporary(id);
    h.up.say(id, 'Keep the zebras');
    h.up.answer(id, 'Kept.');
    await history.saveTemporary(id);
    expect(history.conversations.map(c => c.id)).toEqual([id]);
    expect(history.get(id)?.temporary).toBe(false);
    expect(await history.search('zebras')).toHaveLength(1);
  });

  it('leaves locked chats out of search', async () => {
    const id = await chat('Diary', [['Dear diary', 'Go on.']]);
    await open();
    expect(await history.search('diary')).toHaveLength(1);
    await history.setLocked(id, true);
    expect(history.get(id)?.locked).toBe(true);
    expect(await history.search('diary')).toHaveLength(0);
  });

  it('branches into a new chat that says where it came from', async () => {
    const id = await chat('Route planning', [
      ['First leg?', 'Porto to Coimbra.'],
      ['Second leg?', 'Coimbra to Lisbon.'],
    ]);
    await open();
    const thread = await history.thread(id);
    expect(thread.map(m => m.role)).toEqual([
      'user',
      'assistant',
      'user',
      'assistant',
    ]);
    const branch = await history.branch(id, thread[1].id);
    expect(branch.id).not.toBe(id);
    expect(branch.title).toBe('Branch · Route planning');
    expect(branch.branchedFrom?.conversationId).toBe(id);
    expect((await history.thread(branch.id)).map(m => m.text)).toEqual([
      'First leg?',
      'Porto to Coimbra.',
    ]);
    expect(history.conversations.map(c => c.id)).toContain(branch.id);
  });

  it('deletes one chat, and all of them', async () => {
    const a = await chat('A', [['Q', 'A']]);
    const b = await chat('B', [['Q', 'A']]);
    await open();
    await history.setArchived(b, true);
    await history.remove(a);
    expect(history.get(a)).toBeUndefined();
    expect(h.up.sessions.has(a)).toBe(false);
    await history.removeAll();
    expect(history.archived()).toHaveLength(0);
    expect(h.up.sessions.size).toBe(0);
  });

  it('exports Markdown, plain text and ChatGPT’s format', async () => {
    const id = await chat('Café: plans/ideas?', [
      ['What is 2 + 2?', 'It is **4**.'],
    ]);
    await open();
    const labels = {user: 'You', assistant: 'AntiChat'};

    const markdown = await history.exportChat(id, 'markdown', labels);
    expect(markdown.fileName).toBe('Cafe-plans-ideas.md');
    expect(markdown.content).toContain('# Café: plans/ideas?');
    expect(markdown.content).toContain('**You**\n\nWhat is 2 + 2?');
    expect(markdown.content).toContain('**AntiChat**\n\nIt is **4**.');

    const text = await history.exportChat(id, 'text', labels);
    expect(text.mimeType).toBe('text/plain');
    expect(text.content).toBe(
      'Café: plans/ideas?\n\nYou:\nWhat is 2 + 2?\n\nAntiChat:\nIt is **4**.\n',
    );

    const json = await history.exportChat(id, 'chatgpt', labels);
    expect(json.fileName).toBe('Cafe-plans-ideas.json');
    const [conversation] = JSON.parse(json.content);
    expect(conversation.title).toBe('Café: plans/ideas?');
    expect(typeof conversation.mapping).toBe('object');
    expect(conversation.current_node).toBeTruthy();
  });

  it('puts the list back when a write fails', async () => {
    const id = await chat('Stays', [['Q', 'A']]);
    await open();
    port.rename = async () => {
      throw new Error('disk full');
    };
    await expect(history.rename(id, 'Never saved')).rejects.toThrow(
      'disk full',
    );
    expect(history.get(id)?.title).toBe('Stays');
  });
});

describe('history helpers', () => {
  it('flattens highlighted runs into text and ranges', () => {
    expect(
      flattenSegments([
        {text: '…the ', match: false},
        {text: 'quick', match: true},
        {text: ' brown ', match: false},
        {text: 'fox', match: true},
      ]),
    ).toEqual({
      text: '…the quick brown fox',
      matches: [
        [5, 10],
        [17, 20],
      ],
    });
  });

  it('makes safe file names', () => {
    expect(exportFileName('', 'md')).toBe('chat.md');
    expect(exportFileName('../../etc/passwd', 'txt')).toBe('etc-passwd.txt');
    expect(exportFileName('日本語のタイトル', 'json')).toBe(
      '日本語のタイトル.json',
    );
    expect(exportFileName('x'.repeat(200), 'md').length).toBe(63);
  });

  it('writes a thread as plain text', () => {
    expect(
      threadAsPlainText(
        '',
        [
          {id: '1', role: 'user', text: ' Hi ', createdAt: 0},
          {id: '2', role: 'assistant', text: '', createdAt: 0},
          {id: '3', role: 'assistant', text: 'Hello.', createdAt: 0},
        ],
        {user: 'You', assistant: 'AntiChat'},
      ),
    ).toBe('You:\nHi\n\nAntiChat:\nHello.\n');
  });
});
