import {Db} from '../driver';
import {listHistory} from '../history';
import {CORE_SCHEMA_VERSION, migrate, registerMigrations} from '../schema';
import {searchConversations} from '../search';
import {ConversationStore} from '../ConversationStore';
import {FakeUpstream} from './support/fakeUpstream';
import {createHarness, Harness} from './support/harness';
import {openNodeSqlite} from './support/nodeDriver';

const DAY = 24 * 60 * 60 * 1000;

describe('schema', () => {
  it('creates every table, including the reserved ones, and is idempotent', async () => {
    const driver = openNodeSqlite();
    const db = new Db(driver);
    expect(await migrate(db)).toEqual({core: CORE_SCHEMA_VERSION});
    expect(await migrate(db)).toEqual({core: CORE_SCHEMA_VERSION});
    const tables = (
      await db.all<{name: string}>(
        "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
      )
    ).map(row => row.name);
    for (const name of [
      'nodes',
      'session_meta',
      'messages_fts',
      'titles_fts',
      'memories',
      'projects',
      'files',
      'chunks',
      'vectors',
      'tasks',
      'schema_migrations',
    ]) {
      expect(tables).toContain(name);
    }
    for (const name of [
      'memories',
      'projects',
      'files',
      'chunks',
      'vectors',
      'tasks',
    ]) {
      const row = await db.get<{c: number}>(
        `SELECT count(*) AS c FROM ${name}`,
      );
      expect(row!.c).toBe(0);
    }
    driver.close();
  });

  it('lets another milestone add its own versioned steps', async () => {
    const driver = openNodeSqlite();
    const db = new Db(driver);
    await migrate(db);
    registerMigrations('test-memory', [
      {version: 1, statements: ['ALTER TABLE memories ADD COLUMN score REAL']},
    ]);
    expect(await migrate(db)).toMatchObject({'test-memory': 1});
    registerMigrations('test-memory', [
      {version: 1, statements: ['ALTER TABLE memories ADD COLUMN score REAL']},
      {
        version: 2,
        statements: ['CREATE INDEX memories_score ON memories (score)'],
      },
    ]);
    expect(await migrate(db)).toMatchObject({'test-memory': 2});
    expect(() => registerMigrations('core', [])).toThrow();
    registerMigrations('test-memory', []);
    driver.close();
  });

  it('rolls a failed unit of work back', async () => {
    const driver = openNodeSqlite();
    const db = new Db(driver);
    await migrate(db);
    await expect(
      db.transaction(async () => {
        await db.run(
          "INSERT INTO projects (id, name, created_at, updated_at) VALUES ('p', 'P', 1, 1)",
        );
        throw new Error('boom');
      }),
    ).rejects.toThrow('boom');
    expect(await db.get('SELECT 1 AS x FROM projects')).toBeUndefined();
    driver.close();
  });
});

describe('migration of chats that already exist upstream', () => {
  it('adopts every existing chat on first launch and forgets deleted ones', async () => {
    const driver = openNodeSqlite();
    const db = new Db(driver);
    const up = new FakeUpstream();
    const a = up.addSession('Old chat A');
    up.say(a, 'hello from before');
    up.answer(a, 'hi, I predate antichat.db');
    const b = up.addSession('Old chat B');
    up.sessions.get(b)!.pinned = true;
    up.say(b, 'pinned one');
    const empty = up.addSession('Empty');

    const store = new ConversationStore({
      db,
      upstream: up,
      now: () => up.clock,
    });
    await store.init();
    expect((await store.getPath(a)).map(node => node.text)).toEqual([
      'hello from before',
      'hi, I predate antichat.db',
    ]);
    expect((await store.getMeta(b))!.pinnedAt).not.toBeNull();
    expect((await store.getMeta(empty))!.currentLeafId).toBeNull();
    expect(await store.stats()).toEqual({
      sessions: 3,
      nodes: 3,
      parkedNodes: 0,
      temporarySessions: 0,
    });
    const hits = await searchConversations(db, 'predate');
    expect(hits[0].sessionId).toBe(a);

    // Second launch: nothing to do. A chat deleted by upstream code goes.
    await store.init();
    const before = db.mutations;
    await store.syncAll();
    expect(db.mutations).toBe(before);
    await up.deleteSessions([a]);
    await store.syncAll();
    expect(await store.getMeta(a)).toBeNull();
    expect(await searchConversations(db, 'predate')).toEqual([]);
    driver.close();
  });
});

describe('chat flags and history', () => {
  let h: Harness;
  beforeEach(async () => {
    h = await createHarness();
  });
  afterEach(() => h.close());

  async function chat(title: string, ageDays: number, now: number) {
    const s = h.up.addSession(title);
    const message = h.up.say(s, `about ${title}`);
    message.createdAt = now - ageDays * DAY;
    h.up.sessions.get(s)!.createdAt = message.createdAt;
    await h.store.syncSession(s);
    return s;
  }

  it('groups by date like the ChatGPT drawer, pins first', async () => {
    const now = new Date(2026, 10, 24, 15, 0, 0).getTime();
    const today = await chat('today', 0, now);
    const yesterday = await chat('yesterday', 1, now);
    await chat('three days', 3, now);
    await chat('seven days', 7, now);
    await chat('twenty days', 20, now);
    await chat('october', 45, now);
    await chat('august', 100, now);
    await chat('last year', 400, now);
    const pinnedOld = await chat('pinned old', 200, now);
    await h.store.setPinned(pinnedOld, true);
    h.up.tick();
    await h.store.setPinned(yesterday, true);

    const listing = await listHistory(h.db, {now});
    expect(listing.pinned.map(item => item.title)).toEqual([
      'yesterday',
      'pinned old',
    ]);
    expect(
      listing.groups.map(group => [group.label, group.items.map(i => i.title)]),
    ).toEqual([
      ['Today', ['today']],
      ['Previous 7 Days', ['three days', 'seven days']],
      ['Previous 30 Days', ['twenty days']],
      ['October', ['october']],
      ['August', ['august']],
      ['2025', ['last year']],
    ]);
    expect(listing.groups[3]).toMatchObject({
      key: 'month',
      month: 9,
      year: 2026,
    });
    expect(h.up.sessions.get(yesterday)!.pinned).toBe(true);

    await h.store.setPinned(yesterday, false);
    const after = await listHistory(h.db, {now});
    expect(after.pinned.map(item => item.title)).toEqual(['pinned old']);
    expect(after.groups[1].label).toBe('Yesterday');
    expect(today).toBeTruthy();
  });

  it('archives and unarchives', async () => {
    const now = h.up.clock + DAY;
    const a = await chat('keep', 0, now);
    const b = await chat('archive me', 0, now);
    await h.store.setArchived(b, true);
    const titles = async (scope?: 'active' | 'archived' | 'all') =>
      (await listHistory(h.db, {now, scope})).groups.flatMap(group =>
        group.items.map(item => item.title),
      );
    expect(await titles()).toEqual(['keep']);
    expect(await titles('archived')).toEqual(['archive me']);
    expect((await titles('all')).sort()).toEqual(['archive me', 'keep']);
    expect(await searchConversations(h.db, 'archive')).toEqual([]);
    expect(
      (await searchConversations(h.db, 'archive', {includeArchived: true}))[0],
    ).toMatchObject({sessionId: b, archived: true});
    // Archiving does not touch upstream's rows or the tree.
    await h.expectInStep(b);

    await h.store.setArchived(b, false);
    expect((await titles()).sort()).toEqual(['archive me', 'keep']);
    expect(a).toBeTruthy();
  });

  it('renames in both stores and in the title index', async () => {
    const s = h.up.addSession('New Session');
    h.up.say(s, 'hello');
    await h.store.syncSession(s);
    await h.store.rename(s, 'Quarterly budget review');
    expect(h.up.sessions.get(s)!.title).toBe('Quarterly budget review');
    expect((await h.store.getMeta(s))!.title).toBe('Quarterly budget review');
    expect((await searchConversations(h.db, 'budget'))[0].titleMatched).toBe(
      true,
    );
    expect(await searchConversations(h.db, 'session')).toEqual([]);

    // A title upstream sets by itself (auto-title) arrives with the next sync.
    h.up.sessions.get(s)!.title = 'Budget, renamed upstream';
    await h.store.syncSession(s);
    expect((await searchConversations(h.db, 'upstream'))[0].sessionId).toBe(s);
  });

  it('locks, files into a project, and filters on both', async () => {
    const now = h.up.clock + DAY;
    const s = await chat('secret diary', 0, now);
    const other = await chat('groceries', 0, now);
    await h.store.setLocked(s, true);
    await h.store.setProject(other, 'project-1');
    expect((await h.store.getMeta(s))!.locked).toBe(true);
    const listing = await listHistory(h.db, {now});
    expect(
      listing.groups[0].items.find(item => item.sessionId === s)!.locked,
    ).toBe(true);
    expect(await searchConversations(h.db, 'diary')).toEqual([]);
    expect(
      (await searchConversations(h.db, 'diary', {includeLocked: true}))[0]
        .locked,
    ).toBe(true);
    expect(
      (await listHistory(h.db, {now, projectId: 'project-1'})).groups[0].items,
    ).toHaveLength(1);
    expect(
      (await listHistory(h.db, {now, projectId: null})).groups[0].items,
    ).toHaveLength(1);
    await h.store.setLocked(s, false);
    await h.store.setProject(other, null);
    expect((await h.store.getMeta(other))!.projectId).toBeNull();
    await expect(h.store.setLocked('nope', true)).rejects.toThrow(
      'Unknown chat',
    );
  });

  it('deletes one chat and many, with their versions and index rows', async () => {
    const now = h.up.clock + DAY;
    const ids = [
      await chat('alpha unique', 0, now),
      await chat('beta unique', 0, now),
      await chat('gamma unique', 0, now),
    ];
    const q = h.up.messages.get(ids[0])![0];
    await h.truncate(ids[0], q.id);
    h.up.say(ids[0], 'edited alpha');
    await h.store.syncSession(ids[0]);
    expect(await h.nodeCount(ids[0])).toBe(2);

    await h.store.deleteSession(ids[0]);
    expect(await h.nodeCount(ids[0])).toBe(0);
    expect(h.up.sessions.has(ids[0])).toBe(false);
    expect(
      await searchConversations(h.db, 'alpha', {includeParked: true}),
    ).toEqual([]);

    await h.store.deleteSessions([ids[1], ids[2]]);
    await h.store.deleteSessions([]);
    expect(await h.store.stats()).toMatchObject({sessions: 0, nodes: 0});
    expect(await searchConversations(h.db, 'unique')).toEqual([]);
    expect((await listHistory(h.db, {now})).groups).toEqual([]);
  });
});

describe('temporary chat', () => {
  let h: Harness;
  beforeEach(async () => {
    h = await createHarness();
  });
  afterEach(() => h.close());

  it('is never written to the tree, the history or the index', async () => {
    const s = h.up.addSession('New Session');
    await h.store.markTemporary(s);
    h.up.say(s, 'my secret zebra question');
    h.up.answer(s, 'a zebra answer');
    await h.store.syncSession(s);
    h.up.sessions.get(s)!.title = 'Zebra chat';
    await h.store.syncAll();
    await h.store.rename(s, 'Zebra talk');

    expect(await h.nodeCount()).toBe(0);
    expect((await h.store.getMeta(s))!.title).toBe('');
    expect(
      await searchConversations(h.db, 'zebra', {includeParked: true}),
    ).toEqual([]);
    const listing = await listHistory(h.db, {scope: 'all'});
    expect(listing.groups).toEqual([]);
    // Nothing of the content reached the database file.
    const dump = JSON.stringify([
      await h.db.all('SELECT * FROM session_meta'),
      await h.db.all('SELECT * FROM nodes'),
      await h.db.all(
        "SELECT * FROM messages_fts WHERE messages_fts MATCH 'zebra'",
      ),
      await h.db.all("SELECT * FROM titles_fts WHERE titles_fts MATCH 'zebra'"),
    ]);
    expect(dump.toLowerCase()).not.toContain('zebra');
    // Edit and branch are no-ops or refused.
    await h.store.beforeTruncate(s, h.up.messages.get(s)![0].id, true);
    await expect(
      h.store.branch(s, h.up.messages.get(s)![0].id),
    ).rejects.toThrow();
    expect(await h.nodeCount()).toBe(0);
  });

  it('is deleted when discarded, and at the next launch after a crash', async () => {
    const s = h.up.addSession('New Session');
    await h.store.markTemporary(s);
    h.up.say(s, 'gone soon');
    await h.store.discardTemporary(s);
    expect(h.up.sessions.has(s)).toBe(false);
    expect(await h.store.getMeta(s)).toBeNull();

    const crashed = h.up.addSession('New Session');
    await h.store.markTemporary(crashed);
    h.up.say(crashed, 'left behind by a crash');
    const normal = h.up.addSession('Normal');
    h.up.say(normal, 'stays');
    await h.store.init(); // next launch
    expect(h.up.sessions.has(crashed)).toBe(false);
    expect(h.up.sessions.has(normal)).toBe(true);
    // discardTemporary never deletes a normal chat.
    await h.store.discardTemporary(normal);
    expect(h.up.sessions.has(normal)).toBe(true);
  });

  it('can be kept, and then behaves like any chat', async () => {
    const s = h.up.addSession('Zebra facts');
    await h.store.markTemporary(s);
    h.up.say(s, 'zebra stripes?');
    h.up.answer(s, 'Each zebra has a unique pattern.');
    await h.store.keepTemporary(s);
    await h.expectInStep(s);
    expect((await searchConversations(h.db, 'zebra'))[0].sessionId).toBe(s);
    expect(
      (await listHistory(h.db, {now: h.up.clock})).groups[0].items,
    ).toHaveLength(1);
  });

  it('turning a saved chat temporary removes what was stored', async () => {
    const s = h.up.addSession('Was saved');
    h.up.say(s, 'zebra');
    await h.store.syncSession(s);
    await h.store.markTemporary(s);
    expect(await h.nodeCount()).toBe(0);
    expect(await searchConversations(h.db, 'zebra')).toEqual([]);
    expect(await searchConversations(h.db, 'saved')).toEqual([]);
  });
});
