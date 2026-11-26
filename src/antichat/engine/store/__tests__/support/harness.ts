import {ConversationStore} from '../../ConversationStore';
import {Db} from '../../driver';
import {FakeUpstream} from './fakeUpstream';
import {openNodeSqlite} from './nodeDriver';

export interface Harness {
  store: ConversationStore;
  up: FakeUpstream;
  db: Db;
  close(): void;
  /** Edit or regenerate as upstream does it: hook, then delete the tail. */
  truncate(
    sessionId: string,
    messageId: string,
    include?: boolean,
  ): Promise<void>;
  /** The invariant: upstream holds exactly the tree's visible thread. */
  expectInStep(sessionId: string): Promise<void>;
  nodeCount(sessionId?: string): Promise<number>;
}

export async function createHarness(): Promise<Harness> {
  const driver = openNodeSqlite();
  const db = new Db(driver);
  const up = new FakeUpstream();
  let counter = 0;
  const store = new ConversationStore({
    db,
    upstream: up,
    now: () => up.clock,
    newId: () => `n${++counter}`,
  });
  await store.init();
  return {
    store,
    up,
    db,
    close: () => driver.close(),
    async truncate(sessionId, messageId, include = true) {
      await store.beforeTruncate(sessionId, messageId, include);
      up.truncateFrom(sessionId, messageId, include);
    },
    async expectInStep(sessionId) {
      const path = await store.getPath(sessionId);
      const messages = await up.getMessages(sessionId);
      expect(path.map(node => node.upId)).toEqual(messages.map(m => m.id));
      expect(path.map(node => node.payload)).toEqual(
        messages.map(({id: _id, createdAt: _createdAt, ...payload}) => payload),
      );
      expect(path.map(node => node.depth)).toEqual(path.map((_, i) => i));
      const meta = await store.getMeta(sessionId);
      expect(meta?.currentLeafId ?? null).toBe(
        path.length > 0 ? path[path.length - 1].id : null,
      );
    },
    async nodeCount(sessionId) {
      const row = sessionId
        ? await db.get<{c: number}>(
            'SELECT count(*) AS c FROM nodes WHERE session_id = ?',
            [sessionId],
          )
        : await db.get<{c: number}>('SELECT count(*) AS c FROM nodes');
      return row?.c ?? 0;
    },
  };
}
