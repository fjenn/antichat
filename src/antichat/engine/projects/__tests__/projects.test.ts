import {createEstimatingCounter} from '../../context/tokenCounter';
import {
  createChatHarness,
  type ChatHarness,
} from '../../memory/__tests__/support/memoryHarness';
import {createSystemPromptProvider} from '../../prompt/provider';
import {
  clearRequestProviders,
  prepareRequest,
  registerRequestProvider,
} from '../../prompt/registry';
import {
  PROJECT_BLOCK_ID,
  createProjectProvider,
  fitToTokens,
  projectInstructionBudget,
  renderProjectBlock,
  type ProjectRequestMeta,
} from '../provider';
import {ProjectStore} from '../ProjectStore';
import {MAX_PROJECT_FILES} from '../types';

const NOW = new Date(2026, 10, 24, 14, 5);
const counter = createEstimatingCounter();

describe('projects', () => {
  let h: ChatHarness;
  let projects: ProjectStore;
  let ids: number;

  beforeEach(async () => {
    h = await createChatHarness();
    ids = 0;
    projects = new ProjectStore({
      db: h.db,
      chats: h.chats.store,
      now: () => h.clock.now,
      newId: () => `prj_${++ids}`,
    });
    await projects.init();
  });
  afterEach(() => {
    clearRequestProviders();
    h.close();
  });

  describe('ProjectStore', () => {
    it('creates, reads and edits a project', async () => {
      const project = await projects.create({
        name: '  Thesis   draft ',
        instructions: 'Answer in formal British English.',
        appearance: {icon: 'book', color: '#345'},
      });
      expect(project).toMatchObject({
        id: 'prj_1',
        name: 'Thesis draft',
        instructions: 'Answer in formal British English.',
        memoryScope: 'default',
        appearance: {icon: 'book', color: '#345'},
        archivedAt: null,
      });
      h.clock.now += 1000;
      const edited = await projects.update(project.id, {
        name: 'Thesis',
        memoryScope: 'project',
      });
      expect(edited).toMatchObject({
        name: 'Thesis',
        memoryScope: 'project',
        instructions: 'Answer in formal British English.',
        appearance: {icon: 'book', color: '#345'},
      });
      expect(edited!.updatedAt).toBeGreaterThan(project.updatedAt);
      await expect(projects.create({name: '   '})).rejects.toThrow(
        'needs a name',
      );
      expect(await projects.update('nope', {name: 'x'})).toBeNull();
      expect(await projects.get('nope')).toBeNull();
    });

    it('archives and lists with counts, most recently active first', async () => {
      const a = await projects.create({name: 'Garden'});
      h.clock.now += 1000;
      const b = await projects.create({name: 'Thesis'});
      const chat = await h.addChat('Tomatoes', [
        ['When do I sow tomatoes?', 'March.'],
      ]);
      await projects.moveChat(chat, a.id);
      await projects.attachFile(b.id, {name: 'outline.pdf'});
      await h.store.add({
        text: 'Deadline is 1 March',
        origin: 'user',
        projectId: b.id,
      });
      const list = await projects.list();
      expect(list.map(p => p.name)).toEqual(['Garden', 'Thesis']);
      expect(list[0]).toMatchObject({
        chatCount: 1,
        fileCount: 0,
        memoryCount: 0,
      });
      expect(list[1]).toMatchObject({
        chatCount: 0,
        fileCount: 1,
        memoryCount: 1,
      });
      await projects.update(a.id, {archived: true});
      expect((await projects.list()).map(p => p.name)).toEqual(['Thesis']);
      expect(await projects.list({includeArchived: true})).toHaveLength(2);
      await projects.update(a.id, {archived: false});
      expect((await projects.get(a.id))!.archivedAt).toBeNull();
    });

    it('moves chats in and out through the conversation store', async () => {
      const project = await projects.create({name: 'Garden'});
      const chat = await h.addChat('Tomatoes', [
        ['When do I sow tomatoes?', 'March.'],
      ]);
      expect(await projects.projectOfSession(chat)).toBeNull();
      await projects.moveChat(chat, project.id);
      expect((await projects.projectOfSession(chat))?.id).toBe(project.id);
      expect(await projects.sessionIds(project.id)).toEqual([chat]);
      expect((await h.chats.store.getMeta(chat))?.projectId).toBe(project.id);
      await projects.moveChat(chat, null);
      expect(await projects.sessionIds(project.id)).toEqual([]);
      await expect(projects.moveChat(chat, 'nope')).rejects.toThrow(
        'Unknown project',
      );
      const alone = new ProjectStore({db: h.db});
      await expect(alone.moveChat(chat, project.id)).rejects.toThrow(
        'needs `chats`',
      );
    });

    it('keeps references to attached files', async () => {
      const project = await projects.create({name: 'Thesis'});
      const file = await projects.attachFile(project.id, {
        name: 'outline.pdf',
        mimeType: 'application/pdf',
        size: 120_000,
        uri: 'file:///docs/outline.pdf',
      });
      expect(file).toMatchObject({
        projectId: project.id,
        name: 'outline.pdf',
        status: 'pending',
        size: 120_000,
      });
      await projects.setFileStatus(file.id, 'ready');
      await projects.attachFile(project.id, {name: 'notes.txt'});
      expect(
        (await projects.listFiles(project.id)).map(f => [f.name, f.status]),
      ).toEqual([
        ['outline.pdf', 'ready'],
        ['notes.txt', 'pending'],
      ]);
      // Its chunks and vectors (M10's rows) go with the file.
      await h.db.run(
        "INSERT INTO chunks (file_id, position, text) VALUES (?, 0, 'x')",
        [file.id],
      );
      await projects.removeFile(file.id);
      expect(await projects.listFiles(project.id)).toHaveLength(1);
      expect(await h.db.all('SELECT * FROM chunks')).toEqual([]);
      await expect(projects.attachFile('nope', {name: 'a'})).rejects.toThrow(
        'Unknown project',
      );
    });

    it('caps the number of files', async () => {
      const project = await projects.create({name: 'Big'});
      for (let i = 0; i < MAX_PROJECT_FILES; i++) {
        await projects.attachFile(project.id, {name: `f${i}.txt`});
      }
      await expect(
        projects.attachFile(project.id, {name: 'one-too-many.txt'}),
      ).rejects.toThrow('at most');
    });

    it('deletes a project with its chats, files and memories', async () => {
      const project = await projects.create({name: 'Thesis'});
      const other = await projects.create({name: 'Garden'});
      const chat = await h.addChat('Outline', [['Draft an outline', 'Sure.']]);
      const kept = await h.addChat('Tomatoes', [['Sow tomatoes?', 'March.']]);
      await projects.moveChat(chat, project.id);
      await projects.moveChat(kept, other.id);
      await projects.attachFile(project.id, {name: 'outline.pdf'});
      await h.store.add({
        text: 'Deadline is 1 March',
        origin: 'user',
        projectId: project.id,
      });
      await h.store.add({text: 'User is vegetarian', origin: 'user'});
      await projects.delete(project.id);
      expect(await projects.get(project.id)).toBeNull();
      expect(await h.chats.store.getMeta(chat)).toBeNull();
      expect(await h.chats.store.getMeta(kept)).not.toBeNull();
      expect(await h.db.all('SELECT * FROM files')).toEqual([]);
      expect((await h.store.list()).map(m => m.text)).toEqual([
        'User is vegetarian',
      ]);
    });

    it('can delete a project and keep its chats', async () => {
      const project = await projects.create({name: 'Thesis'});
      const chat = await h.addChat('Outline', [['Draft an outline', 'Sure.']]);
      await projects.moveChat(chat, project.id);
      await projects.delete(project.id, {keepChats: true});
      expect((await h.chats.store.getMeta(chat))?.projectId).toBeNull();
    });

    it('tells listeners about changes', async () => {
      let changes = 0;
      const stop = projects.subscribe(() => changes++);
      const project = await projects.create({name: 'Thesis'});
      await projects.update(project.id, {instructions: 'Be brief.'});
      expect(changes).toBe(2);
      stop();
      await projects.update(project.id, {instructions: 'Be long.'});
      expect(changes).toBe(2);
    });
  });

  describe('project provider', () => {
    const send = (
      sessionId: string | undefined,
      nCtx = 8192,
      temporary = false,
    ) =>
      prepareRequest({
        messages: [{role: 'user', content: 'What next?'}],
        session: {id: sessionId, temporary},
        runtime: {nCtx, family: 'gemma4', now: NOW, tokenCounter: counter},
      });

    beforeEach(() => {
      registerRequestProvider(
        createSystemPromptProvider({personalization: () => null}),
      );
      registerRequestProvider(createProjectProvider({projects}));
    });

    it('applies project instructions only inside the project', async () => {
      const project = await projects.create({
        name: 'Thesis',
        instructions: 'Always answer in formal British English.\nCite sources.',
      });
      const inside = await h.addChat('Outline', [
        ['Draft an outline', 'Sure.'],
      ]);
      const outside = await h.addChat('Dinner', [['Dinner idea?', 'Curry.']]);
      await projects.moveChat(inside, project.id);
      await projects.attachFile(project.id, {name: 'outline.pdf'});

      const withProject = await send(inside);
      const system = String(withProject.messages[0].content);
      expect(system).toContain(
        'This chat is part of the user\'s project "Thesis".\nThe user\'s instructions for every chat in this project:\nAlways answer in formal British English.\nCite sources.\nFiles attached to the project: outline.pdf.',
      );
      // After the stable blocks and the date: the cached prefix is intact.
      expect(system.indexOf('Current date:')).toBeLessThan(
        system.indexOf('This chat is part of'),
      );
      expect(withProject.meta.project as ProjectRequestMeta).toEqual({
        id: project.id,
        name: 'Thesis',
        truncated: false,
        files: 1,
      });

      for (const id of [outside, undefined, 'unknown-chat']) {
        const plain = await send(id);
        expect(String(plain.messages[0].content)).not.toContain('Thesis');
        expect(plain.meta.project).toBeUndefined();
      }
      // Moved out: the instructions stop applying.
      await projects.moveChat(inside, null);
      expect(String((await send(inside)).messages[0].content)).not.toContain(
        'British English',
      );
    });

    it('follows an edit of the instructions and ignores archived projects', async () => {
      const project = await projects.create({
        name: 'Thesis',
        instructions: 'Be brief.',
      });
      const chat = await h.addChat('Outline', [['Draft an outline', 'Sure.']]);
      await projects.moveChat(chat, project.id);
      expect(String((await send(chat)).messages[0].content)).toContain(
        'Be brief.',
      );
      await projects.update(project.id, {instructions: 'Be thorough.'});
      const edited = String((await send(chat)).messages[0].content);
      expect(edited).toContain('Be thorough.');
      expect(edited).not.toContain('Be brief.');
      // Same project state, same bytes.
      expect(String((await send(chat)).messages[0].content)).toBe(edited);
      await projects.update(project.id, {archived: true});
      expect(String((await send(chat)).messages[0].content)).not.toContain(
        'Thesis',
      );
    });

    it('never applies to a temporary chat', async () => {
      const project = await projects.create({
        name: 'Thesis',
        instructions: 'Be brief.',
      });
      const chat = await h.addChat('Outline', [['Draft', 'Sure.']]);
      await projects.moveChat(chat, project.id);
      expect(
        String((await send(chat, 8192, true)).messages[0].content),
      ).not.toContain('Thesis');
    });

    it('cuts long instructions to the budget of the context window', async () => {
      const long = Array.from(
        {length: 200},
        (_, i) => `Rule ${i}: always keep the tone formal and precise.`,
      ).join('\n');
      const project = await projects.create({
        name: 'Rules',
        instructions: long,
      });
      const chat = await h.addChat('Chat', [['hi', 'hello']]);
      await projects.moveChat(chat, project.id);
      const small = await send(chat, 4096);
      const large = await send(chat, 16384);
      const tokens = async (text: string) => counter.countText(text);
      const block = (prepared: Awaited<ReturnType<typeof send>>) =>
        String(prepared.messages[0].content).split('This chat is part of')[1];
      expect(await tokens(block(small))).toBeLessThanOrEqual(
        projectInstructionBudget(4096) + 40,
      );
      expect(block(large).length).toBeGreaterThan(block(small).length);
      expect((small.meta.project as ProjectRequestMeta).truncated).toBe(true);
      // Cut at a line end, not in the middle of a rule.
      expect(block(small).trimEnd().endsWith('precise.')).toBe(true);
      expect(projectInstructionBudget(4096)).toBe(328);
      expect(projectInstructionBudget(1000)).toBe(200);
      expect(projectInstructionBudget(200000)).toBe(1500);
    });

    it('renders a project without instructions or files', async () => {
      const project = await projects.create({name: 'Empty'});
      expect(renderProjectBlock(project, '', [])).toBe(
        'This chat is part of the user\'s project "Empty".',
      );
      expect(await fitToTokens('short text', 50, counter)).toEqual({
        text: 'short text',
        truncated: false,
      });
      expect(PROJECT_BLOCK_ID).toBe('project');
    });
  });
});
