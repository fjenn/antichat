import {BRANCH_TITLE_PREFIX} from '../ConversationStore';
import {createHarness, Harness} from './support/harness';

describe('conversation tree', () => {
  let h: Harness;
  let s: string;

  beforeEach(async () => {
    h = await createHarness();
    s = h.up.addSession('Trip plan');
  });
  afterEach(() => h.close());

  /** q1 a1 q2 a2 in upstream, synced. */
  async function seed() {
    const q1 = h.up.say(s, 'Where should I go in May?');
    const a1 = h.up.answer(s, 'Lisbon is lovely in May.');
    const q2 = h.up.say(s, 'What about food?');
    const a2 = h.up.answer(s, 'Try pastel de nata.');
    await h.store.syncSession(s);
    return {q1, a1, q2, a2};
  }

  it('mirrors a linear chat and stays in step while it streams', async () => {
    const {a2} = await seed();
    await h.expectInStep(s);
    expect(await h.nodeCount(s)).toBe(4);

    h.up.rewrite(s, a2.id, 'Try pastel de nata and grilled sardines.');
    await h.store.syncSession(s);
    await h.expectInStep(s);
    expect(await h.nodeCount(s)).toBe(4);
    const thread = await h.store.getThread(s);
    expect(thread[3].text).toBe('Try pastel de nata and grilled sardines.');
    expect(thread.every(m => m.versionCount === 1)).toBe(true);
  });

  it('syncing twice changes nothing', async () => {
    await seed();
    const before = h.db.mutations;
    await h.store.syncSession(s);
    expect(h.db.mutations).toBe(before);
  });

  it('edit keeps the replaced tail as a version of the edited message', async () => {
    const {q2} = await seed();
    await h.truncate(s, q2.id);
    await h.store.syncSession(s);
    await h.expectInStep(s);
    expect(await h.nodeCount(s)).toBe(4); // parked, not deleted

    h.up.say(s, 'What about museums?');
    h.up.answer(s, 'The Gulbenkian.');
    await h.store.syncSession(s);
    await h.expectInStep(s);
    expect(await h.nodeCount(s)).toBe(6);

    const thread = await h.store.getThread(s);
    expect(thread.map(m => m.text)).toEqual([
      'Where should I go in May?',
      'Lisbon is lovely in May.',
      'What about museums?',
      'The Gulbenkian.',
    ]);
    expect(thread[2].versionCount).toBe(2);
    expect(thread[2].versionIndex).toBe(1);
    expect(thread[3].versionCount).toBe(1);
  });

  it('regenerate adds a second answer under the same prompt', async () => {
    const {q2} = await seed();
    // Upstream's "try again" deletes the prompt too and sends it again.
    await h.truncate(s, q2.id);
    h.up.say(s, 'What about food?');
    h.up.answer(s, 'Bacalhau, in a hundred ways.');
    await h.store.syncSession(s);
    await h.expectInStep(s);

    expect(await h.nodeCount(s)).toBe(5); // the prompt node is reused
    const thread = await h.store.getThread(s);
    expect(thread[2].versionCount).toBe(1);
    expect(thread[3].versionCount).toBe(2);
    expect(thread[3].versionIndex).toBe(1);
    expect(thread[3].text).toBe('Bacalhau, in a hundred ways.');
  });

  it('version switch swaps tails both ways and loses nothing', async () => {
    const {q2} = await seed();
    await h.truncate(s, q2.id);
    h.up.say(s, 'What about museums?');
    const a2b = h.up.answer(s, 'The Gulbenkian.');
    h.up.say(s, 'Opening hours?');
    h.up.answer(s, 'Ten to six, closed Tuesdays.');
    await h.store.syncSession(s);
    expect(await h.nodeCount(s)).toBe(8);

    const edited = (await h.store.getThread(s))[2];
    let thread = await h.store.switchVersion(s, edited.messageId, 'previous');
    await h.expectInStep(s);
    expect(h.up.texts(s)).toEqual([
      'Where should I go in May?',
      'Lisbon is lovely in May.',
      'What about food?',
      'Try pastel de nata.',
    ]);
    expect(thread[2].versionIndex).toBe(0);
    expect(await h.nodeCount(s)).toBe(8);

    thread = await h.store.switchVersion(s, thread[2].messageId, 'next');
    await h.expectInStep(s);
    expect(h.up.texts(s)).toEqual([
      'Where should I go in May?',
      'Lisbon is lovely in May.',
      'What about museums?',
      'The Gulbenkian.',
      'Opening hours?',
      'Ten to six, closed Tuesdays.',
    ]);
    expect(await h.nodeCount(s)).toBe(8);
    // The swapped-in rows keep working with upstream: it can append again.
    expect(thread[3].nodeId).toBe(a2b.id);
    h.up.say(s, 'Thanks');
    await h.store.syncSession(s);
    await h.expectInStep(s);
    expect(await h.nodeCount(s)).toBe(9);

    // Out of range is clamped, not an error.
    thread = await h.store.switchVersion(s, thread[2].messageId, 7);
    expect(thread[2].versionIndex).toBe(1);
  });

  it('nested versions remember the tail each one last showed', async () => {
    const {q1, q2} = await seed();
    // Regenerate a2 twice.
    await h.truncate(s, q2.id);
    h.up.say(s, 'What about food?');
    h.up.answer(s, 'Second answer.');
    await h.store.syncSession(s);
    let thread = await h.store.getThread(s);
    await h.truncate(s, thread[2].messageId);
    h.up.say(s, 'What about food?');
    h.up.answer(s, 'Third answer.');
    await h.store.syncSession(s);
    thread = await h.store.getThread(s);
    expect(thread[3].versionCount).toBe(3);

    // Show answer 2, then edit the very first message.
    thread = await h.store.switchVersion(s, thread[3].messageId, 1);
    expect(thread[3].text).toBe('Second answer.');
    await h.truncate(s, q1.id);
    h.up.say(s, 'Where should I go in June?');
    h.up.answer(s, 'Porto.');
    await h.store.syncSession(s);
    await h.expectInStep(s);
    thread = await h.store.getThread(s);
    expect(thread[0].versionCount).toBe(2);
    expect(thread).toHaveLength(2);

    // Back to the first version of the first message: its tail returns
    // exactly as it was left, on answer 2 of 3.
    thread = await h.store.switchVersion(s, thread[0].messageId, 0);
    await h.expectInStep(s);
    expect(thread.map(m => m.text)).toEqual([
      'Where should I go in May?',
      'Lisbon is lovely in May.',
      'What about food?',
      'Second answer.',
    ]);
    expect(thread[3].versionIndex).toBe(1);
    expect(thread[3].versionCount).toBe(3);
    expect(await h.nodeCount(s)).toBe(8);
  });

  it('a random walk of edits, regenerations and switches never loses a node', async () => {
    await seed();
    let seedValue = 42;
    const random = (n: number) => {
      seedValue = (seedValue * 48271) % 2147483647;
      return seedValue % n;
    };
    const everSeen = new Set<string>();
    for (let step = 0; step < 120; step++) {
      const thread = await h.store.getThread(s);
      const action = random(4);
      if (action === 0 || thread.length === 0) {
        h.up.say(s, `question ${step}`);
        h.up.answer(s, `answer ${step}`);
      } else if (action === 1) {
        const users = thread.filter(m => m.role === 'user');
        const target = users[random(users.length)];
        await h.truncate(s, target.messageId);
        h.up.say(s, `edited ${step}`);
        h.up.answer(s, `answer to edited ${step}`);
      } else if (action === 2) {
        const users = thread.filter(m => m.role === 'user');
        const target = users[random(users.length)];
        await h.truncate(s, target.messageId);
        h.up.say(s, target.text);
        h.up.answer(s, `regenerated ${step}`);
      } else {
        const multi = thread.filter(m => m.versionCount > 1);
        if (multi.length > 0) {
          const target = multi[random(multi.length)];
          await h.store.switchVersion(
            s,
            target.messageId,
            random(target.versionCount),
          );
        }
      }
      await h.store.syncSession(s);
      await h.expectInStep(s);
      const all = await h.store.getAllNodes(s);
      const ids = new Set(all.map(node => node.id));
      for (const id of everSeen) {
        expect(ids.has(id)).toBe(true);
      }
      for (const id of ids) {
        everSeen.add(id);
      }
      // The tree stays a tree: every parent exists, depth = parent + 1.
      const byId = new Map(all.map(node => [node.id, node]));
      for (const node of all) {
        if (node.parentId) {
          expect(byId.get(node.parentId)!.depth).toBe(node.depth - 1);
        } else {
          expect(node.depth).toBe(0);
        }
      }
    }
    expect(everSeen.size).toBeGreaterThan(100);
  });

  it('a reply upstream deletes by itself is removed, not kept as a version', async () => {
    const {a2} = await seed();
    h.up.removeOne(s, a2.id); // failed or withdrawn generation
    await h.store.syncSession(s);
    await h.expectInStep(s);
    expect(await h.nodeCount(s)).toBe(3);
    h.up.answer(s, 'Second try.');
    await h.store.syncSession(s);
    expect((await h.store.getThread(s))[3].versionCount).toBe(1);
  });

  it('a sync in the middle of a truncation does not bring the tail back', async () => {
    const {q2, a2} = await seed();
    await h.store.beforeTruncate(s, q2.id, true);
    // Upstream has deleted only one of the two rows so far.
    h.up.removeOne(s, a2.id);
    await h.store.syncSession(s);
    expect((await h.store.getPath(s)).map(n => n.id)).toHaveLength(2);
    h.up.removeOne(s, q2.id);
    await h.store.syncSession(s);
    await h.expectInStep(s);
    expect(await h.nodeCount(s)).toBe(4);
  });

  it('recovers when the app died between upstream and tree writes of a swap', async () => {
    const {q2} = await seed();
    await h.truncate(s, q2.id);
    h.up.say(s, 'What about museums?');
    h.up.answer(s, 'The Gulbenkian.');
    await h.store.syncSession(s);
    const all = await h.store.getAllNodes(s);
    const parked = all.filter(node => !node.onPath);
    // Upstream already holds the parked tail (ids = node ids); the tree
    // still thinks the other version is showing.
    await h.up.replaceTail(
      s,
      2,
      parked.map(node => ({
        ...node.payload,
        id: node.id,
        createdAt: node.createdAt,
      })),
    );
    await h.store.syncSession(s);
    await h.expectInStep(s);
    expect(await h.nodeCount(s)).toBe(6);
    expect(h.up.texts(s)[3]).toBe('Try pastel de nata.');
  });

  it('branches into a new chat with the thread up to the chosen message', async () => {
    const {a1} = await seed();
    const branchId = await h.store.branch(s, a1.id);
    await h.expectInStep(branchId);
    await h.expectInStep(s);
    expect(h.up.texts(branchId)).toEqual([
      'Where should I go in May?',
      'Lisbon is lovely in May.',
    ]);
    const meta = await h.store.getMeta(branchId);
    expect(meta).toMatchObject({
      title: `${BRANCH_TITLE_PREFIX}Trip plan`,
      originKind: 'branch',
      originSessionId: s,
      originNodeId: a1.id,
    });
    // Independent copies: continuing the branch leaves the source alone.
    h.up.say(branchId, 'And in winter?');
    await h.store.syncSession(branchId);
    expect(await h.nodeCount(s)).toBe(4);
    expect(await h.nodeCount(branchId)).toBe(3);
    // A branch of a branch does not stack the prefix.
    const second = await h.store.branch(
      branchId,
      h.up.messages.get(branchId)![0].id,
    );
    expect((await h.store.getMeta(second))!.title).toBe(
      `${BRANCH_TITLE_PREFIX}Trip plan`,
    );
  });

  it('showNode brings a parked message back into the thread', async () => {
    const {q2, a2} = await seed();
    await h.truncate(s, q2.id);
    h.up.say(s, 'What about museums?');
    h.up.answer(s, 'The Gulbenkian.');
    await h.store.syncSession(s);
    const thread = await h.store.showNode(s, a2.id);
    await h.expectInStep(s);
    expect(thread.map(m => m.text)).toContain('Try pastel de nata.');
    expect(await h.nodeCount(s)).toBe(6);
  });

  it('notifies listeners only when something changed', async () => {
    await seed();
    const listener = jest.fn();
    const off = h.store.onChange(listener);
    await h.store.syncSession(s);
    expect(listener).not.toHaveBeenCalled();
    h.up.say(s, 'One more');
    await h.store.syncSession(s);
    expect(listener).toHaveBeenCalledTimes(1);
    off();
    await h.store.setArchived(s, true);
    expect(listener).toHaveBeenCalledTimes(1);
  });
});
