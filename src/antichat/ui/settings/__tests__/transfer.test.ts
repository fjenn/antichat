import {strFromU8, unzipSync} from 'fflate';

import {
  buildChatGptArchive,
  readChatGptArchive,
} from '../../../engine/store/archive';
import {base64ToBytes, bytesToBase64} from '../data/base64';
import {
  exportChats,
  exportFileName,
  importChats,
  type ArchiveStore,
  type TransferDevice,
} from '../data/transfer';

const conversation = (id: string) => ({
  id,
  conversation_id: id,
  title: `Chat ${id}`,
  create_time: 1,
  update_time: 2,
  mapping: {},
});

function memoryStore(initial: unknown[] = []): ArchiveStore & {
  chats: unknown[];
} {
  const chats = [...initial];
  return {
    chats,
    exportConversations: async () => chats,
    exportArchive: async () => buildChatGptArchive(chats),
    importArchive: async bytes => {
      const incoming = readChatGptArchive(bytes);
      chats.push(...incoming);
      return {
        imported: incoming.map((_, index) => `s${index}`),
        skipped: 0,
        failed: 0,
      };
    },
  };
}

function memoryDevice(pick: {name: string; base64: string} | null = null) {
  const files = new Map<string, string>();
  const shared: Array<{path: string; mimeType: string}> = [];
  const device: TransferDevice = {
    writeTemp: async (fileName, base64) => {
      files.set(`/cache/${fileName}`, base64);
      return `/cache/${fileName}`;
    },
    share: async (path, mimeType) => {
      shared.push({path, mimeType});
    },
    pickFile: async () => pick,
  };
  return {device, files, shared};
}

describe('base64', () => {
  it('round-trips bytes of every length', () => {
    for (let length = 0; length < 70; length++) {
      const bytes = Uint8Array.from({length}, (_, index) => (index * 37) % 256);
      const text = bytesToBase64(bytes);
      expect(text).toBe(Buffer.from(bytes).toString('base64'));
      expect(Array.from(base64ToBytes(text))).toEqual(Array.from(bytes));
    }
  });

  it('handles a large buffer', () => {
    const bytes = Uint8Array.from({length: 50_000}, (_, index) => index % 251);
    expect(Array.from(base64ToBytes(bytesToBase64(bytes)))).toEqual(
      Array.from(bytes),
    );
  });
});

describe('export', () => {
  it('writes a ChatGPT-format zip and opens the share sheet', async () => {
    const store = memoryStore([conversation('a'), conversation('b')]);
    const {device, files, shared} = memoryDevice();
    const outcome = await exportChats(
      store,
      device,
      new Date('2026-11-24T10:00:00Z'),
    );
    expect(outcome).toEqual({
      kind: 'shared',
      count: 2,
      path: '/cache/antichat-chats-2026-11-24.zip',
    });
    expect(shared).toEqual([
      {
        path: '/cache/antichat-chats-2026-11-24.zip',
        mimeType: 'application/zip',
      },
    ]);
    // What was written is what ChatGPT's own export looks like.
    const zip = unzipSync(
      base64ToBytes(files.get(outcome.kind === 'shared' ? outcome.path : '')!),
    );
    const parsed = JSON.parse(strFromU8(zip['conversations.json']));
    expect(parsed.map((chat: {id: string}) => chat.id)).toEqual(['a', 'b']);
  });

  it('says so when there is nothing to export', async () => {
    const {device, shared} = memoryDevice();
    expect(await exportChats(memoryStore(), device)).toEqual({kind: 'empty'});
    expect(shared).toHaveLength(0);
  });

  it('names the file by date', () => {
    expect(exportFileName(new Date('2026-01-02T03:04:05Z'))).toBe(
      'antichat-chats-2026-01-02.zip',
    );
  });
});

describe('import', () => {
  it('reads a ChatGPT zip the user picked', async () => {
    const zip = buildChatGptArchive([conversation('x'), conversation('y')]);
    const store = memoryStore();
    const {device} = memoryDevice({
      name: 'export.zip',
      base64: bytesToBase64(zip),
    });
    expect(await importChats(store, device)).toEqual({
      kind: 'imported',
      count: 2,
      skipped: 0,
      failed: 0,
    });
    expect(store.chats).toHaveLength(2);
  });

  it('reads a bare conversations.json', async () => {
    const json = Buffer.from(JSON.stringify([conversation('z')])).toString(
      'base64',
    );
    const store = memoryStore();
    const {device} = memoryDevice({name: 'conversations.json', base64: json});
    const outcome = await importChats(store, device);
    expect(outcome.kind === 'imported' && outcome.count).toBe(1);
  });

  it('does nothing when the picker is cancelled', async () => {
    const store = memoryStore();
    expect(await importChats(store, memoryDevice(null).device)).toEqual({
      kind: 'cancelled',
    });
    expect(store.chats).toHaveLength(0);
  });

  it('rejects a file that is not an export', async () => {
    const {device} = memoryDevice({
      name: 'notes.txt',
      base64: Buffer.from('hello').toString('base64'),
    });
    await expect(importChats(memoryStore(), device)).rejects.toBeDefined();
  });

  it('exports, then imports the same file into an empty store', async () => {
    const from = memoryStore([conversation('a'), conversation('b')]);
    const out = memoryDevice();
    const exported = await exportChats(from, out.device);
    const path = exported.kind === 'shared' ? exported.path : '';
    const into = memoryStore();
    const outcome = await importChats(
      into,
      memoryDevice({name: 'x.zip', base64: out.files.get(path)!}).device,
    );
    expect(outcome.kind === 'imported' && outcome.count).toBe(2);
    expect(into.chats).toEqual(from.chats);
  });
});
