import {MemoryStore, memoryValue} from '../MemoryStore';
import {DEFAULT_MEMORY_SETTINGS, type MemoryEvent} from '../types';
import {createMemoryHarness, type MemoryHarness} from './support/memoryHarness';

const DAY = 86_400_000;

describe('MemoryStore', () => {
  let h: MemoryHarness;
  let events: MemoryEvent[];

  beforeEach(async () => {
    h = await createMemoryHarness();
    events = [];
    h.store.subscribe(event => events.push(event));
  });
  afterEach(() => h.close());

  const add = (text: string, extra: Record<string, unknown> = {}) =>
    h.store.add({text, origin: 'user', ...extra});

  it('adds, reads and lists memories, pinned first then newest', async () => {
    const a = await add('User is vegetarian', {kind: 'profile'});
    h.clock.now += 1000;
    const b = await add('User lives in Lyon', {kind: 'profile'});
    h.clock.now += 1000;
    await h.store.setPinned(a!.id, true);
    const list = await h.store.list();
    expect(list.map(item => item.text)).toEqual([
      'User is vegetarian',
      'User lives in Lyon',
    ]);
    expect(list[0].pinned).toBe(true);
    expect(await h.store.get(b!.id)).toMatchObject({
      text: 'User lives in Lyon',
      kind: 'profile',
      origin: 'user',
      projectId: null,
      useCount: 0,
    });
    expect(await h.store.count()).toBe(2);
    expect(events[0]).toMatchObject({type: 'saved'});
  });

  it('searches by words with stemming, best first', async () => {
    await add('User has two dogs called Rex and Bo');
    await add('User is training for a marathon');
    await add('User likes cooking Persian food');
    const hits = await h.store.searchText('what should my dog eat?');
    expect(hits.map(hit => hit.item.text)).toEqual([
      'User has two dogs called Rex and Bo',
    ]);
    expect(await h.store.searchText('the of')).toEqual([]);
    const list = await h.store.list({search: 'marathons'});
    expect(list).toHaveLength(1);
  });

  it('finds an exact duplicate whatever the wording around it', async () => {
    const saved = await add('User is vegetarian.');
    expect((await h.store.findExact('the user is Vegetarian', null))?.id).toBe(
      saved!.id,
    );
    expect(await h.store.findExact('User is vegan', null)).toBeNull();
    expect(await h.store.findExact('User is vegetarian', 'p1')).toBeNull();
  });

  it('keeps the old text on an edit and can undo it', async () => {
    const saved = await add('User lives in Munich');
    const revision = h.store.revision;
    const edited = await h.store.update(saved!.id, {
      text: 'User lives in Berlin',
    });
    expect(edited).toMatchObject({
      text: 'User lives in Berlin',
      previousText: 'User lives in Munich',
    });
    expect(h.store.revision).toBeGreaterThan(revision);
    expect(events[events.length - 1]).toMatchObject({
      type: 'updated',
      previousText: 'User lives in Munich',
    });
    // The index follows the edit.
    expect(await h.store.searchText('Munich')).toHaveLength(0);
    expect(await h.store.searchText('Berlin')).toHaveLength(1);
    const undone = await h.store.undoUpdate(saved!.id);
    expect(undone?.text).toBe('User lives in Munich');
  });

  it('deletes a memory and leaves a tombstone without its text', async () => {
    const saved = await add('User is vegetarian');
    expect(await h.store.delete([saved!.id])).toBe(1);
    expect(await h.store.get(saved!.id)).toBeNull();
    expect(await h.store.searchText('vegetarian')).toHaveLength(0);
    expect(await h.store.isTombstoned('The user is a vegetarian.')).toBe(true);
    expect(await h.store.isTombstoned('User is vegan')).toBe(false);
    const rows = await h.db.all('SELECT * FROM memory_tombstones');
    expect(JSON.stringify(rows)).not.toContain('vegetarian');
    await h.store.clearTombstone('User is vegetarian');
    expect(await h.store.isTombstoned('User is vegetarian')).toBe(false);
    expect(events[events.length - 1]).toEqual({
      type: 'deleted',
      ids: [saved!.id],
      reason: 'user',
    });
  });

  it('deletes everything, tombstones and use records included', async () => {
    const a = await add('User is vegetarian');
    const b = await add('User lives in Lyon');
    await h.store.delete([b!.id]);
    await h.store.recordUse('s1', [{memoryId: a!.id, how: 'always'}]);
    expect(await h.store.deleteAll()).toBe(1);
    expect(await h.store.count()).toBe(0);
    for (const table of [
      'memories',
      'memory_uses',
      'memory_use_items',
      'memory_tombstones',
    ]) {
      const row = await h.db.get<{c: number}>(
        `SELECT count(*) AS c FROM ${table}`,
      );
      expect(row?.c).toBe(0);
    }
    expect(events[events.length - 1]).toEqual({type: 'cleared'});
  });

  it('deletes one project’s memories only', async () => {
    await add('User is vegetarian');
    await add('Deadline is in March', {projectId: 'p1'});
    expect(await h.store.deleteAll({projectId: 'p1'})).toBe(1);
    expect((await h.store.list()).map(item => item.text)).toEqual([
      'User is vegetarian',
    ]);
  });

  it('writes nothing while paused or switched off, and remembers the switch', async () => {
    await h.store.setPaused(true);
    expect(await add('User is vegetarian')).toBeNull();
    expect(h.store.canWrite).toBe(false);
    await h.store.updateSettings({paused: false, enabled: false});
    expect(await add('User is vegetarian')).toBeNull();
    // Settings survive a restart.
    const again = new MemoryStore({db: h.db});
    await again.init();
    expect(again.getSettings()).toEqual({
      ...DEFAULT_MEMORY_SETTINGS,
      enabled: false,
    });
  });

  it('counts a destructive change as a revision, an addition not', async () => {
    const start = h.store.revision;
    const saved = await add('User is vegetarian');
    expect(h.store.revision).toBe(start);
    await h.store.delete([saved!.id]);
    expect(h.store.revision).toBe(start + 1);
    await h.store.updateSettings({enabled: false});
    expect(h.store.revision).toBe(start + 2);
    await h.store.setPaused(true);
    expect(h.store.revision).toBe(start + 2);
  });

  it('values importance, recency and use', () => {
    const base = {
      id: 'x',
      text: 't',
      origin: 'user' as const,
      projectId: null,
      pinned: false,
      sensitive: null,
      sourceSessionId: null,
      sourceNodeId: null,
      createdAt: 0,
      updatedAt: 0,
      lastUsedAt: null,
      useCount: 0,
      previousText: null,
    };
    const now = 400 * DAY;
    const profile = {...base, kind: 'profile' as const, importance: 0.7};
    const context = {...base, kind: 'context' as const, importance: 0.7};
    // Passing context fades faster than a profile fact.
    expect(memoryValue(profile, now)).toBeGreaterThan(
      memoryValue(context, now),
    );
    // Being used keeps a memory alive.
    expect(
      memoryValue({...context, lastUsedAt: now, useCount: 5}, now),
    ).toBeGreaterThan(memoryValue(profile, now));
    expect(memoryValue({...profile, importance: 0.9}, now)).toBeGreaterThan(
      memoryValue(profile, now),
    );
  });

  it('evicts the least valuable unpinned memory above the cap', async () => {
    await h.store.updateSettings({maxItems: 10});
    const pinned = await add('Old pinned fact', {
      kind: 'context',
      importance: 0.1,
      pinned: true,
    });
    const weak = await add('Old weak context', {
      kind: 'context',
      importance: 0.2,
    });
    for (let i = 0; i < 8; i++) {
      await add(`Profile fact number ${i}`, {kind: 'profile', importance: 0.8});
    }
    expect(await h.store.count()).toBe(10);
    h.clock.now += 30 * DAY;
    const newest = await add('Brand new low-importance note', {
      kind: 'context',
      importance: 0.1,
    });
    expect(await h.store.count()).toBe(10);
    expect(await h.store.get(weak!.id)).toBeNull();
    // Pinned memories and the one just written are spared.
    expect(await h.store.get(pinned!.id)).not.toBeNull();
    expect(await h.store.get(newest!.id)).not.toBeNull();
    expect(events).toContainEqual({
      type: 'deleted',
      ids: [weak!.id],
      reason: 'evicted',
    });
    // Eviction is not a user deletion: no tombstone.
    expect(await h.store.isTombstoned('Old weak context')).toBe(false);
    // Lowering the cap evicts at once.
    await h.store.updateSettings({maxItems: 10});
    expect(await h.store.count()).toBe(10);
  });

  it('shows a chat the memories of its scope', async () => {
    await add('User is vegetarian');
    await add('Client is called Acme', {projectId: 'p1'});
    await add('Budget is 10k', {projectId: 'p2'});
    const texts = async (scope: object) =>
      (await h.store.visible(scope)).map(item => item.text);
    expect(await texts({})).toEqual(['User is vegetarian']);
    expect(await texts({projectId: 'p1'})).toEqual([
      'User is vegetarian',
      'Client is called Acme',
    ]);
    expect(await texts({projectId: 'p1', projectOnly: true})).toEqual([
      'Client is called Acme',
    ]);
    expect(
      (await h.store.searchText('Acme client', {})).map(hit => hit.item.text),
    ).toEqual([]);
    expect(await h.store.list({projectId: null})).toHaveLength(1);
    expect(await h.store.list({projectId: 'p2'})).toHaveLength(1);
    expect(await h.store.list()).toHaveLength(3);
  });

  it('records which memories an answer had, and which it used', async () => {
    const diet = await add('User is vegetarian', {kind: 'profile'});
    const home = await add('User lives in Lyon', {kind: 'profile'});
    expect(await h.store.recordUse('s1', [])).toBeNull();
    const useId = await h.store.recordUse('s1', [
      {memoryId: diet!.id, how: 'always'},
      {memoryId: home!.id, how: 'retrieved'},
    ]);
    expect(await h.store.useForMessage('m7')).toBeNull();
    h.clock.now += 5000;
    await h.store.confirmUse(useId!, {messageId: 'm7', citedIds: [diet!.id]});
    const use = await h.store.useForMessage('m7');
    expect(use).toMatchObject({id: useId, sessionId: 's1', messageId: 'm7'});
    expect(use!.items).toEqual([
      {
        memoryId: diet!.id,
        text: 'User is vegetarian',
        kind: 'profile',
        how: 'always',
        cited: true,
      },
      {
        memoryId: home!.id,
        text: 'User lives in Lyon',
        kind: 'profile',
        how: 'retrieved',
        cited: false,
      },
    ]);
    // Being used counts for ranking.
    expect(await h.store.get(diet!.id)).toMatchObject({
      useCount: 1,
      lastUsedAt: h.clock.now,
    });
    expect((await h.store.get(home!.id))!.useCount).toBe(0);
    expect(await h.store.usesForSession('s1')).toHaveLength(1);
    // A deleted memory disappears from old answers' sources too.
    await h.store.delete([diet!.id]);
    expect((await h.store.useForMessage('m7'))!.items).toHaveLength(1);
    await h.store.delete([home!.id]);
    expect(await h.store.useForMessage('m7')).toBeNull();
  });

  it('tracks how far the background pass has read each chat', async () => {
    expect(await h.store.extractedThrough('s1')).toBe(0);
    await h.store.markExtracted('s1', 12);
    await h.store.markExtracted('s1', 8);
    expect(await h.store.extractedThrough('s1')).toBe(12);
  });

  it('clips long text and refuses empty text', async () => {
    const long = await add(`User ${'really '.repeat(80)}likes tea`);
    expect(long!.text.length).toBeLessThanOrEqual(241);
    expect(await add('   ')).toBeNull();
  });
});
