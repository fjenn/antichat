import {Db} from '../../../store/driver';
import {
  createHarness,
  type Harness,
} from '../../../store/__tests__/support/harness';
import {openNodeSqlite} from '../../../store/__tests__/support/nodeDriver';
import {registerProjectMigrations} from '../../../projects/schema';
import {DigestStore} from '../../digest';
import {VectorStore} from '../../embeddings/vectorStore';
import {MemoryStore} from '../../MemoryStore';
import {registerMemoryMigrations} from '../../schema';
import {MemoryWriter, type MemoryWriterOptions} from '../../writer';

export interface MemoryHarness {
  db: Db;
  store: MemoryStore;
  writer: MemoryWriter;
  vectors: VectorStore;
  digests: DigestStore;
  clock: {now: number};
  close(): void;
}

/** antichat.db in memory with the memory schema; no conversation store. */
export async function createMemoryHarness(
  options: Partial<MemoryWriterOptions> = {},
): Promise<MemoryHarness> {
  registerMemoryMigrations();
  registerProjectMigrations();
  const driver = openNodeSqlite();
  const db = new Db(driver);
  const clock = {now: 1_780_000_000_000};
  let counter = 0;
  const store = new MemoryStore({
    db,
    now: () => clock.now,
    newId: () => `mem_${++counter}`,
  });
  await store.init();
  const vectors = new VectorStore(db);
  return {
    db,
    store,
    vectors,
    digests: new DigestStore(db, () => clock.now),
    writer: new MemoryWriter({store, vectors, ...options}),
    clock,
    close: () => driver.close(),
  };
}

export interface ChatHarness extends MemoryHarness {
  chats: Harness;
  /** Adds a chat with alternating user / assistant messages; returns its id. */
  addChat(title: string, turns: Array<[string, string]>): Promise<string>;
}

/** The conversation store (M3) and the memory engine on one database. */
export async function createChatHarness(
  options: Partial<MemoryWriterOptions> = {},
): Promise<ChatHarness> {
  registerMemoryMigrations();
  registerProjectMigrations();
  const chats = await createHarness();
  const clock = {
    get now() {
      return chats.up.clock;
    },
    set now(value: number) {
      chats.up.clock = value;
    },
  };
  let counter = 0;
  const store = new MemoryStore({
    db: chats.db,
    now: () => clock.now,
    newId: () => `mem_${++counter}`,
  });
  await store.init();
  const vectors = new VectorStore(chats.db);
  return {
    chats,
    db: chats.db,
    store,
    vectors,
    digests: new DigestStore(chats.db, () => clock.now),
    writer: new MemoryWriter({store, vectors, ...options}),
    clock,
    close: () => chats.close(),
    async addChat(title, turns) {
      const id = chats.up.addSession(title);
      for (const [user, assistant] of turns) {
        chats.up.say(id, user);
        chats.up.answer(id, assistant);
      }
      await chats.store.syncSession(id);
      return id;
    },
  };
}
