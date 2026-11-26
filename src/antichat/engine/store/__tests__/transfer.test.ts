import {strToU8, zipSync} from 'fflate';
import {readFileSync} from 'fs';
import {join} from 'path';

import {buildChatGptArchive, readChatGptArchive} from '../archive';
import {parseChatGptConversation} from '../chatgpt';
import {
  exportArchive,
  exportConversations,
  exportSessionMarkdown,
  importArchive,
  importConversations,
} from '../transfer';
import {createHarness, Harness} from './support/harness';

const fixture: any[] = JSON.parse(
  readFileSync(
    join(__dirname, '../fixtures/chatgpt-export/conversations.json'),
    'utf8',
  ),
);

/** The zip ChatGPT e-mails: conversations.json among other files. */
function fixtureZip(): Uint8Array {
  return zipSync({
    'user.json': strToU8('{"id":"user-fixture","email":"nobody@example.com"}'),
    'message_feedback.json': strToU8('[]'),
    'shared_conversations.json': strToU8('[]'),
    'chat.html': strToU8('<html><body>fixture</body></html>'),
    'conversations.json': strToU8(JSON.stringify(fixture)),
    'file-Qm3xT9fakeAssetPointer-IMG_2291.jpeg': new Uint8Array([
      255, 216, 255,
    ]),
  });
}

const byTitle = (list: any[], title: string) =>
  list.find(conversation => conversation.title === title);

describe('ChatGPT export format', () => {
  let h: Harness;
  beforeEach(async () => {
    h = await createHarness();
  });
  afterEach(() => h.close());

  it('imports a ChatGPT export archive', async () => {
    const result = await importArchive(h.store, fixtureZip());
    expect(result.imported).toHaveLength(5);
    expect(result.skipped).toBe(1); // the chat with nothing visible
    expect(result.failed).toBe(0);
    for (const sessionId of result.imported) {
      await h.expectInStep(sessionId);
      // A sync right after import finds nothing to do.
      const before = h.db.mutations;
      await h.store.syncSession(sessionId);
      expect(h.db.mutations).toBe(before);
    }
  });

  it('shows the current path and keeps the other versions', async () => {
    const {imported} = await importConversations(h.store, fixture);
    const metas = await Promise.all(imported.map(id => h.store.getMeta(id)));
    const kyoto = metas.find(meta => meta!.title.startsWith('Kyoto'))!;
    expect(h.up.texts(kyoto.sessionId).map(text => text.slice(0, 24))).toEqual([
      'Plan 3 days in Kyoto in ',
      'Here is a quieter plan b',
      'Which of these need a re',
      'Only Shugaku-in Imperial',
    ]);
    const thread = await h.store.getThread(kyoto.sessionId);
    expect(thread[0]).toMatchObject({versionIndex: 1, versionCount: 2});
    expect(thread[1]).toMatchObject({versionIndex: 1, versionCount: 2});
    expect(await h.nodeCount(kyoto.sessionId)).toBe(7);

    // The imported tree behaves like a native one.
    const back = await h.store.switchVersion(
      kyoto.sessionId,
      thread[0].messageId,
      'previous',
    );
    await h.expectInStep(kyoto.sessionId);
    expect(back.map(m => m.text.slice(0, 12))).toEqual([
      'Plan 3 days ',
      'Day 1: Arash',
    ]);
    expect(await h.nodeCount(kyoto.sessionId)).toBe(7);
  });

  it('maps hidden reasoning, tool and context nodes sensibly', async () => {
    const {imported} = await importConversations(h.store, fixture);
    const metas = await Promise.all(imported.map(id => h.store.getMeta(id)));
    const fx = metas.find(meta => meta!.title === 'EUR/USD today')!;
    const path = await h.store.getPath(fx.sessionId);
    expect(path.map(node => node.role)).toEqual([
      'user',
      'assistant',
      'user',
      'assistant',
    ]);
    expect(path[1].payload.type).toBe('assistant_turn');
    expect(path[1].payload.metadata.steps[0].reasoningContent).toContain(
      'search rather than answer from memory',
    );
    expect(path[1].payload.metadata.importedModel).toBe('gpt-5-5-thinking');

    const plant = metas.find(meta => meta!.title === 'Identify a houseplant')!;
    expect(plant.archivedAt).not.toBeNull();
    expect(h.up.texts(plant.sessionId)[0]).toBe(
      'What plant is this, and why are the leaf tips brown?',
    );
  });

  it('exports an untouched import back to the same JSON', async () => {
    await importConversations(h.store, fixture);
    const exported = await exportConversations(h.store);
    expect(exported).toHaveLength(5);
    for (const original of fixture.filter(c => c.title !== 'New chat')) {
      expect(byTitle(exported, original.title)).toEqual(original);
    }
  });

  it('survives zip → import → export zip → import on a second device', async () => {
    await importArchive(h.store, fixtureZip());
    const archive = await exportArchive(h.store);
    const again = readChatGptArchive(archive);
    const other = await createHarness();
    try {
      const result = await importConversations(other.store, again);
      expect(result.imported).toHaveLength(5);
      const exported = await exportConversations(other.store);
      for (const original of fixture.filter(c => c.title !== 'New chat')) {
        expect(byTitle(exported, original.title)).toEqual(original);
      }
    } finally {
      other.close();
    }
  });

  it('skips conversations that were imported before', async () => {
    await importConversations(h.store, fixture);
    const second = await importConversations(h.store, fixture);
    expect(second.imported).toHaveLength(0);
    expect(second.skipped).toBe(6);
    const copy = await importConversations(h.store, fixture, {
      duplicates: 'copy',
    });
    expect(copy.imported).toHaveLength(5);
  });

  it('exports a chat that grew after import with the new nodes attached', async () => {
    const {imported} = await importConversations(h.store, fixture);
    const metas = await Promise.all(imported.map(id => h.store.getMeta(id)));
    const sour = metas.find(meta => meta!.title.startsWith('Sourdough'))!;
    const s = sour.sessionId;
    h.up.say(s, 'How warm should the kitchen be?');
    const reply = h.up.answer(s, 'Around 24 to 26 °C.');
    await h.store.syncSession(s);
    // Edit the very first message too: a second root-level version.
    const first = (await h.store.getThread(s))[0];
    await h.truncate(s, first.messageId);
    const edited = h.up.say(s, 'Is my starter dead?');
    await h.store.syncSession(s);

    const [conversation] = await exportConversations(h.store, [s]);
    const original = byTitle(fixture, sour.title);
    const mapping = conversation.mapping;
    expect(Object.keys(mapping)).toHaveLength(
      Object.keys(original.mapping).length + 3,
    );
    expect(conversation.current_node).toBe(edited.id);
    // The edited first message hangs under the same hidden system node as
    // the original first message.
    const originalFirst =
      mapping[first.versionIds[0]] ??
      mapping[
        Object.keys(original.mapping).find(
          key => original.mapping[key].message?.author.role === 'user',
        )!
      ];
    expect(mapping[edited.id].parent).toBe(originalFirst.parent);
    expect(mapping[mapping[edited.id].parent].children).toContain(edited.id);
    expect(mapping[reply.id].message.content.parts).toEqual([
      'Around 24 to 26 °C.',
    ]);
    // Every parent/children pair agrees.
    for (const entry of Object.values<any>(mapping)) {
      for (const child of entry.children) {
        expect(mapping[child].parent).toBe(entry.id);
      }
      if (entry.parent) {
        expect(mapping[entry.parent].children).toContain(entry.id);
      }
    }
  });

  it('exports native chats as a tree and re-imports them losslessly', async () => {
    const s = h.up.addSession('Native chat');
    h.up.say(s, 'First question', ['file:///photo.jpg']);
    h.up.answer(s, 'First answer', 'thinking it through');
    const q2 = h.up.say(s, 'Second question');
    h.up.answer(s, 'Second answer');
    await h.store.syncSession(s);
    await h.truncate(s, q2.id);
    h.up.say(s, 'Second question');
    h.up.answer(s, 'Second answer, regenerated');
    await h.store.syncSession(s);
    await h.store.setPinned(s, true);

    const [conversation] = await exportConversations(h.store, [s]);
    expect(conversation.title).toBe('Native chat');
    expect(conversation.conversation_id).toBe(s);
    const entries = Object.values<any>(conversation.mapping);
    expect(entries).toHaveLength(6); // synthetic root + 5 nodes
    const root = entries.find(entry => entry.parent === null);
    expect(root.message).toBeNull();
    const firstUser = conversation.mapping[root.children[0]];
    expect(firstUser.message.author.role).toBe('user');
    expect(firstUser.message.content.content_type).toBe('multimodal_text');
    const parsed = parseChatGptConversation(conversation)!;
    expect(parsed.nodes).toHaveLength(5);
    expect(parsed.nodes.filter(node => node.onPath)).toHaveLength(4);

    const other = await createHarness();
    try {
      const result = await importConversations(other.store, [conversation]);
      const copy = result.imported[0];
      await other.expectInStep(copy);
      // Upstream rows come back byte for byte (reasoning, images, flags).
      const strip = (list: any[]) =>
        list.map(({id: _id, ...message}) => message);
      expect(strip(await other.up.getMessages(copy))).toEqual(
        strip(await h.up.getMessages(s)),
      );
      expect((await other.store.getMeta(copy))!.pinnedAt).not.toBeNull();
      const thread = await other.store.getThread(copy);
      expect(thread[3]).toMatchObject({versionIndex: 1, versionCount: 2});
      // And a second export is identical to the first.
      const [again] = await exportConversations(other.store, [copy]);
      expect(again).toEqual(conversation);
    } finally {
      other.close();
    }
  });

  it('tolerates damaged conversations', async () => {
    const good = fixture[0];
    const noChildren = JSON.parse(JSON.stringify(good));
    for (const entry of Object.values<any>(noChildren.mapping)) {
      delete entry.children;
    }
    delete noChildren.current_node;
    noChildren.conversation_id = 'no-children';
    noChildren.title = null;
    const dangling = JSON.parse(JSON.stringify(good));
    dangling.conversation_id = 'dangling';
    dangling.current_node = 'gone';
    const firstKey = Object.keys(dangling.mapping)[1];
    dangling.mapping[firstKey].children.push('missing-node');

    const result = await importConversations(h.store, [
      null,
      'text',
      {title: 'no mapping'},
      noChildren,
      dangling,
    ]);
    expect(result.failed).toBe(3);
    expect(result.imported).toHaveLength(2);
    for (const sessionId of result.imported) {
      await h.expectInStep(sessionId);
      expect(h.up.texts(sessionId)).toHaveLength(4);
    }
    expect((await h.store.getMeta(result.imported[0]))!.title).toBe('Untitled');
  });

  it('reads bare JSON and sharded archives, rejects a zip without conversations', () => {
    expect(readChatGptArchive(strToU8(JSON.stringify(fixture)))).toHaveLength(
      6,
    );
    const sharded = zipSync({
      'export/conversations-000.json': strToU8(
        JSON.stringify(fixture.slice(0, 2)),
      ),
      'export/conversations-001.json': strToU8(
        JSON.stringify(fixture.slice(2)),
      ),
    });
    expect(readChatGptArchive(sharded)).toHaveLength(6);
    expect(readChatGptArchive(buildChatGptArchive(fixture))).toEqual(fixture);
    expect(() =>
      readChatGptArchive(zipSync({'notes.txt': strToU8('hello')})),
    ).toThrow('No conversations.json');
  });

  it('exports one chat as Markdown', async () => {
    const s = h.up.addSession('Trip  plan');
    h.up.say(s, 'Where to?', ['file:///a.jpg', 'file:///b.jpg']);
    h.up.answer(s, 'Lisbon.\n\n- sun\n- food');
    await h.store.syncSession(s);
    const markdown = await exportSessionMarkdown(h.store, s);
    expect(markdown).toBe(
      [
        '# Trip plan',
        '',
        `_${new Date(h.up.sessions.get(s)!.createdAt).toISOString().slice(0, 10)}_`,
        '',
        '**You**',
        '',
        '_[2 images]_',
        '',
        'Where to?',
        '',
        '**AntiChat**',
        '',
        'Lisbon.',
        '',
        '- sun',
        '- food',
        '',
      ].join('\n'),
    );
  });
});
