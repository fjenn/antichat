/**
 * On-device checks for the conversation store: every operation, run
 * against the real thing (op-sqlite, WatermelonDB, upstream's
 * ChatSessionStore). Used by `StoreDevScreen`.
 */
import * as RNFS from '@dr.pogodin/react-native-fs';
import {open} from '@op-engineering/op-sqlite';
import {Platform} from 'react-native';

import {database} from '../../../../database';
import {chatSessionRepository} from '../../../../repositories/ChatSessionRepository';
import {chatSessionStore} from '../../../../store/ChatSessionStore';
import {assistant, user} from '../../../../utils/chat';
import type {MessageType} from '../../../../utils/types';
import {conversationAdapter} from '../../../adapters/conversation';
import {ConversationStore} from '../ConversationStore';
import {Db} from '../driver';
import {deleteOpSqlite, openOpSqlite} from '../driver.opsqlite';
import {searchConversations} from '../search';
import {importConversations} from '../transfer';
import type {UpMessage, UpSession} from '../types';
import type {UpstreamGateway} from '../upstream';

export interface CheckResult {
  name: string;
  ok: boolean;
  detail: string;
  ms: number;
}

export interface CheckReport {
  platform: string;
  startedAt: string;
  finished: boolean;
  passed: number;
  failed: number;
  results: CheckResult[];
}

export const REPORT_FILE = 'antichat-store-dev.json';
const TAG = '[dev]';

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) {
    throw new Error(message);
  }
}

/** JSON with object keys sorted, so key order does not matter. */
function canonical(value: unknown): string {
  return JSON.stringify(value, (_key, item) =>
    item && typeof item === 'object' && !Array.isArray(item)
      ? Object.fromEntries(
          Object.keys(item)
            .sort()
            .map(key => [key, item[key]]),
        )
      : item,
  );
}

function same(actual: unknown, expected: unknown, what: string) {
  const a = canonical(actual);
  const b = canonical(expected);
  assert(
    a === b,
    `${what}: expected ${String(b).slice(0, 300)}, got ${String(a).slice(0, 300)}`,
  );
}

const userText = (text: string): MessageType.Text => ({
  id: '',
  author: user,
  type: 'text',
  text,
  createdAt: Date.now(),
  metadata: {},
});

const assistantTurn = (text: string): MessageType.AssistantTurn => ({
  id: '',
  author: assistant,
  type: 'assistant_turn',
  createdAt: Date.now(),
  steps: [{content: text}],
  metadata: {copyable: true},
});

/** What upstream's chat screen shows, oldest first. */
function shown(sessionId: string): string[] {
  const session = chatSessionStore.sessions.find(s => s.id === sessionId);
  return [...(session?.messages ?? [])]
    .reverse()
    .map(message =>
      message.type === 'text'
        ? message.text
        : message.type === 'assistant_turn'
          ? message.steps.map(step => step.content ?? '').join('')
          : '',
    );
}

/** A chat made the way upstream makes one: first message creates it. */
async function newChat(title: string, turns: [string, string][]) {
  chatSessionStore.resetActiveSession();
  for (const [question, reply] of turns) {
    await chatSessionStore.addMessageToCurrentSession(userText(question));
    await chatSessionStore.addMessageToCurrentSession(assistantTurn(reply));
  }
  const sessionId = chatSessionStore.activeSessionId;
  assert(sessionId, 'upstream did not create a chat');
  await chatSessionStore.updateSessionTitleBySessionId(sessionId, title);
  return sessionId;
}

async function coexistence(): Promise<string> {
  // op-sqlite: its own SQLite build with FTS5 and sqlite-vec.
  const probe = open({name: 'antichat-probe.db'});
  const version = probe.executeSync('SELECT sqlite_version() AS v').rows[0].v;
  const vec = probe.executeSync('SELECT vec_version() AS v').rows[0].v;
  probe.executeSync('CREATE VIRTUAL TABLE IF NOT EXISTS t USING fts5(body)');
  probe.executeSync('DELETE FROM t');
  probe.executeSync(
    "INSERT INTO t (body) VALUES ('side by side with watermelon')",
  );
  const fts = probe.executeSync(
    "SELECT snippet(t, 0, '[', ']', '…', 4) AS s FROM t WHERE t MATCH 'watermelon'",
  ).rows[0].s;
  const distance = probe.executeSync(
    "SELECT vec_distance_cosine('[1, 0]', '[0, 1]') AS d",
  ).rows[0].d;
  assert(String(fts).includes('[watermelon]'), `FTS5 snippet was ${fts}`);
  assert(Math.abs(Number(distance) - 1) < 1e-6, `vec distance was ${distance}`);

  // WatermelonDB (system SQLite on iOS, its own on Android) at the same time.
  const before = (await chatSessionRepository.getAllSessions()).length;
  const ids: string[] = [];
  for (let i = 0; i < 20; i++) {
    const session = await chatSessionRepository.createSession(
      `${TAG} coexistence ${i}`,
      [userText(`row ${i}`)],
    );
    ids.push(session.id);
    probe.executeSync('INSERT INTO t (body) VALUES (?)', [`interleaved ${i}`]);
  }
  const melon = (await chatSessionRepository.getAllSessions()).length;
  const ours = probe.executeSync(
    "SELECT count(*) AS c FROM t WHERE t MATCH 'interleaved'",
  ).rows[0].c;
  assert(
    melon === before + 20,
    `WatermelonDB has ${melon - before} of 20 rows`,
  );
  assert(ours === 20, `op-sqlite has ${ours} of 20 rows`);
  const reread = await chatSessionRepository.getSessionById(ids[7]);
  assert(reread?.messages.length === 1, 'WatermelonDB row did not read back');
  await chatSessionRepository.deleteSessions(ids);
  const path = probe.getDbPath();
  probe.delete();
  const adapterName = (database.adapter as any)?.underlyingAdapter?.constructor
    ?.name;
  return `op-sqlite SQLite ${version}, sqlite-vec ${vec}, FTS5 ok; WatermelonDB ${adapterName ?? 'adapter'} wrote and read 20 chats in between; ${path}`;
}

/** Upstream stand-in for the latency run: holds nothing, accepts everything. */
class NullUpstream implements UpstreamGateway {
  readonly authors = {user: user.id, assistant: assistant.id};
  private count = 0;
  async listSessions(): Promise<UpSession[]> {
    return [];
  }
  async getSession(): Promise<UpSession | null> {
    return null;
  }
  async getMessages(): Promise<UpMessage[]> {
    return [];
  }
  async createSession(): Promise<string> {
    return `perf-${++this.count}`;
  }
  async replaceTail(): Promise<void> {}
  async renameSession(): Promise<void> {}
  async setPinned(): Promise<void> {}
  async deleteSessions(): Promise<void> {}
}

const WORDS =
  'river mountain invoice kettle saxophone garden tensor holiday budget lantern recipe compiler harbour violin meadow passport quantum sandwich telescope umbrella'.split(
    ' ',
  );

/** Search latency over 5,001 messages in a scratch database file. */
export async function searchLatency(): Promise<string> {
  const name = 'antichat-perf.db';
  try {
    deleteOpSqlite(name);
  } catch {
    // no earlier file
  }
  const driver = openOpSqlite(name);
  try {
    const db = new Db(driver);
    const store = new ConversationStore({db, upstream: new NullUpstream()});
    await store.init();
    let seed = 7;
    const next = (n: number) => {
      seed = (seed * 48271) % 2147483647;
      return seed % n;
    };
    const sentence = (length: number) =>
      Array.from({length}, () => WORDS[next(WORDS.length)]).join(' ');
    const conversation = (c: number, messages: number, extra?: string) => {
      const mapping: Record<string, any> = {};
      let parent: string | null = null;
      for (let m = 0; m < messages; m++) {
        const id = `c${c}-m${m}`;
        const role = m % 2 === 0 ? 'user' : 'assistant';
        mapping[id] = {
          id,
          parent,
          children: [],
          message: {
            id,
            author: {role},
            create_time: 1_790_000_000 + c * 1000 + m,
            content: {
              content_type: 'text',
              parts: [extra ?? sentence(role === 'user' ? 12 : 120)],
            },
          },
        };
        if (parent) {
          mapping[parent].children.push(id);
        }
        parent = id;
      }
      return {
        title: `Chat ${c} ${sentence(3)}`,
        create_time: 1_790_000_000 + c * 1000,
        update_time: 1_790_000_000 + c * 1000 + messages,
        conversation_id: `perf-conv-${c}`,
        current_node: parent,
        mapping,
      };
    };
    const built = performance.now();
    const conversations: unknown[] = [];
    for (let c = 0; c < 100; c++) {
      conversations.push(conversation(c, 50));
    }
    conversations.push(conversation(100, 1, 'where is the xylophone hidden'));
    const imported = await importConversations(store, conversations);
    const fillMs = performance.now() - built;
    const stats = await store.stats();
    assert(stats.nodes === 5001, `expected 5001 messages, have ${stats.nodes}`);
    assert(imported.imported.length === 101, 'not every chat was stored');

    const queries = [
      'xylophone',
      'saxophone garden',
      'quant',
      'holiday budget recipe',
      'tele umb',
    ];
    const times: number[] = [];
    for (let round = 0; round < 10; round++) {
      for (const query of queries) {
        const start = performance.now();
        const hits = await searchConversations(db, query);
        times.push(performance.now() - start);
        assert(hits.length > 0, `no hit for "${query}"`);
        assert(
          hits[0].snippet || hits[0].titleMatched,
          `hit without snippet for "${query}"`,
        );
      }
    }
    times.sort((a, b) => a - b);
    const median = times[Math.floor(times.length / 2)];
    const p95 = times[Math.floor(times.length * 0.95)];
    const worst = times[times.length - 1];
    assert(worst < 100, `slowest search took ${worst.toFixed(1)} ms`);
    return `5,001 messages, 50 searches: median ${median.toFixed(1)} ms, p95 ${p95.toFixed(1)} ms, worst ${worst.toFixed(1)} ms (filling took ${(fillMs / 1000).toFixed(1)} s)`;
  } finally {
    driver.close();
    try {
      deleteOpSqlite(name);
    } catch {
      // leave the scratch file; it is overwritten next time
    }
  }
}

type Check = [name: string, run: () => Promise<string>];

export function buildChecks(): Check[] {
  const port = conversationAdapter();
  const made: string[] = [];
  let main = '';
  let branchId = '';

  const track = (sessionId: string) => {
    made.push(sessionId);
    return sessionId;
  };

  return [
    ['coexistence: op-sqlite beside WatermelonDB', coexistence],

    [
      'clear leftovers of an interrupted run',
      async () => {
        const fixture: {
          title: string;
        }[] = require('../fixtures/chatgpt-export/conversations.json');
        const titles = new Set(fixture.map(item => item.title));
        const stale = (await chatSessionRepository.getAllSessions())
          .filter(
            session => session.title.includes(TAG) || titles.has(session.title),
          )
          .map(session => session.id);
        await port.deleteSessions(stale);
        return `${stale.length} removed`;
      },
    ],

    [
      'migration of chats that exist upstream',
      async () => {
        // Written straight into upstream's tables, behind the store's back.
        const session = await chatSessionRepository.createSession(
          `${TAG} written before antichat.db`,
          // Upstream passes initial messages newest first.
          [assistantTurn('an old answer'), userText('an old question')],
        );
        track(session.id);
        await port.ready();
        const store = await port.store();
        await store.syncAll();
        const thread = await port.getThread(session.id);
        same(
          thread.map(m => m.text),
          ['an old question', 'an old answer'],
          'migrated thread',
        );
        const stats = await store.stats();
        return `${stats.sessions} chats, ${stats.nodes} nodes in antichat.db`;
      },
    ],

    [
      'send through upstream, tree follows',
      async () => {
        main = track(
          await newChat(`${TAG} Trip plan`, [
            ['Where should I go in May?', 'Lisbon is lovely in May.'],
            ['What about food?', 'Try pastel de nata.'],
          ]),
        );
        const thread = await port.getThread(main);
        same(thread.length, 4, 'thread length');
        assert(
          thread.every(m => m.versionCount === 1),
          'a fresh chat has one version of everything',
        );
        return thread.map(m => m.text).join(' | ');
      },
    ],

    [
      'edit keeps the replaced tail (real upstream edit path)',
      async () => {
        const before = await port.getThread(main);
        chatSessionStore.enterEditMode(before[2].messageId);
        await chatSessionStore.commitEdit(); // calls the ANTICHAT hook
        await chatSessionStore.addMessageToCurrentSession(
          userText('What about museums?'),
        );
        await chatSessionStore.addMessageToCurrentSession(
          assistantTurn('The Gulbenkian.'),
        );
        const thread = await port.getThread(main);
        same(thread[2].versionCount, 2, 'versions of the edited message');
        same(thread[2].versionIndex, 1, 'showing the new version');
        const store = await port.store();
        same((await store.getAllNodes(main)).length, 6, 'nodes kept');
        return `message 3 is now ${thread[2].versionIndex + 1}/${thread[2].versionCount}`;
      },
    ],

    [
      'regenerate adds an answer version (real upstream path)',
      async () => {
        const before = await port.getThread(main);
        // useMessageActions.handleTryAgain: drop the prompt, send it again.
        await chatSessionStore.removeMessagesFromId(before[2].messageId, true);
        await chatSessionStore.addMessageToCurrentSession(
          userText('What about museums?'),
        );
        await chatSessionStore.addMessageToCurrentSession(
          assistantTurn('MAAT, by the river.'),
        );
        const thread = await port.getThread(main);
        same(thread[2].versionCount, 2, 'prompt versions unchanged');
        same(thread[3].versionCount, 2, 'answer versions');
        const store = await port.store();
        same((await store.getAllNodes(main)).length, 7, 'nodes kept');
        return `answer is now ${thread[3].versionIndex + 1}/${thread[3].versionCount}`;
      },
    ],

    [
      'version switch swaps the tail in upstream tables',
      async () => {
        let thread = await port.getThread(main);
        thread = await port.switchVersion(
          main,
          thread[3].messageId,
          'previous',
        );
        same(shown(main)[3], 'The Gulbenkian.', 'chat screen after ‹');
        thread = await port.switchVersion(main, thread[2].messageId, 0);
        same(
          shown(main),
          [
            'Where should I go in May?',
            'Lisbon is lovely in May.',
            'What about food?',
            'Try pastel de nata.',
          ],
          'chat screen on version 1',
        );
        // Upstream can carry on from a swapped-in tail.
        await chatSessionStore.addMessageToCurrentSession(userText('Thanks!'));
        thread = await port.getThread(main);
        same(thread.length, 5, 'thread after appending');
        thread = await port.switchVersion(main, thread[2].messageId, 'next');
        same(shown(main)[3], 'The Gulbenkian.', 'tail remembered');
        const store = await port.store();
        same((await store.getAllNodes(main)).length, 8, 'nodes kept');
        const rows = await chatSessionRepository.getSessionById(main);
        same(rows?.messages.length, 4, 'upstream rows = visible thread');
        return `upstream shows ${shown(main).length} messages, tree holds 8`;
      },
    ],

    [
      'branch into a new chat',
      async () => {
        const thread = await port.getThread(main);
        branchId = track(await port.branch(main, thread[1].messageId));
        const meta = await port.getMeta(branchId);
        same(meta?.originSessionId, main, 'origin');
        assert(meta?.title.startsWith('Branch · '), `title was ${meta?.title}`);
        await chatSessionStore.setActiveSession(branchId);
        same(shown(branchId).length, 2, 'branch thread');
        await chatSessionStore.addMessageToCurrentSession(
          userText('And in winter?'),
        );
        same((await port.getThread(branchId)).length, 3, 'branch continues');
        same((await port.getThread(main)).length, 4, 'source untouched');
        return `${meta?.title} (${branchId})`;
      },
    ],

    [
      'rename, pin, lock',
      async () => {
        await port.rename(branchId, `${TAG} Winter in Lisbon`);
        await port.setPinned(branchId, true);
        await port.setLocked(branchId, true);
        const meta = await port.getMeta(branchId);
        assert(meta?.locked && meta.pinnedAt, 'flags not stored');
        const upstream = chatSessionStore.sessions.find(s => s.id === branchId);
        same(upstream?.title, `${TAG} Winter in Lisbon`, 'upstream title');
        same(upstream?.pinned, true, 'upstream pin');
        const listing = await port.listHistory();
        assert(
          listing.pinned.some(item => item.sessionId === branchId),
          'pinned chat is not first',
        );
        assert(
          (await port.search('winter')).length === 0,
          'a locked chat showed up in search',
        );
        await port.setLocked(branchId, false);
        assert(
          (await port.search('winter'))[0]?.sessionId === branchId,
          'unlocked chat not found',
        );
        await port.setPinned(branchId, false);
        return 'title, pin and lock stored; pin mirrored upstream';
      },
    ],

    [
      'archive and unarchive',
      async () => {
        const titles = async (scope: 'active' | 'archived') => {
          const listing = await port.listHistory({scope});
          return [
            ...listing.pinned,
            ...listing.groups.flatMap(group => group.items),
          ].map(item => item.sessionId);
        };
        await port.setArchived(main, true);
        assert(!(await titles('active')).includes(main), 'still in drawer');
        assert((await titles('archived')).includes(main), 'not in archive');
        assert(
          !(await port.search('pastel')).some(hit => hit.sessionId === main),
          'archived chat in search',
        );
        await port.setArchived(main, false);
        assert((await titles('active')).includes(main), 'not back in drawer');
        return 'left the drawer and search, came back';
      },
    ],

    [
      'history groups',
      async () => {
        const listing = await port.listHistory();
        const today = listing.groups.find(group => group.key === 'today');
        assert(today && today.items.length >= 2, 'no Today group');
        return listing.groups
          .map(group => `${group.label}: ${group.items.length}`)
          .join(', ');
      },
    ],

    [
      'search with snippet and highlight',
      async () => {
        const hits = await port.search('gulben');
        const hit = hits.find(item => item.sessionId === main);
        assert(hit?.snippet, 'no message hit');
        const marked = hit.snippet.segments
          .map(s => (s.match ? `[${s.text}]` : s.text))
          .join('');
        assert(marked.includes('[Gulbenkian]'), `snippet was ${marked}`);
        const byTitle = await port.search('trip pl');
        assert(
          byTitle.some(item => item.sessionId === main && item.titleMatched),
          'title match missing',
        );
        // The parked first version is only found on request.
        same((await port.search('sardines nata')).length, 0, 'no hit expected');
        const parked = await port.search('pastel', {includeParked: true});
        assert(
          parked.some(item => item.snippet && !item.snippet.onActivePath),
          'parked version not searchable',
        );
        return marked;
      },
    ],

    [
      'temporary chat leaves nothing behind',
      async () => {
        chatSessionStore.resetActiveSession();
        port.startTemporaryChat();
        await chatSessionStore.addMessageToCurrentSession(
          userText('a temporary zebra question'),
        );
        await chatSessionStore.addMessageToCurrentSession(
          assistantTurn('a zebra answer'),
        );
        const temporary = chatSessionStore.activeSessionId!;
        await new Promise<void>(resolve => setTimeout(resolve, 600));
        const meta = await port.getMeta(temporary);
        assert(meta?.temporary, 'chat was not marked temporary');
        const store = await port.store();
        same((await store.getAllNodes(temporary)).length, 0, 'nodes written');
        same(
          (await port.search('zebra', {includeParked: true})).length,
          0,
          'search hits',
        );
        const listed = (await port.listHistory({scope: 'all'})).groups.some(
          group => group.items.some(item => item.sessionId === temporary),
        );
        assert(!listed, 'temporary chat is in the history');
        // Leaving the chat deletes it.
        chatSessionStore.resetActiveSession();
        await new Promise<void>(resolve => setTimeout(resolve, 600));
        assert(
          !(await chatSessionRepository.getSessionById(temporary)),
          'upstream rows survived',
        );
        assert(!(await port.getMeta(temporary)), 'meta row survived');
        return 'no nodes, no index rows, deleted on leaving';
      },
    ],

    [
      'export, Markdown, ChatGPT-format round trip',
      async () => {
        const [exported] = await port.exportConversations([main]);
        same(Object.keys(exported.mapping).length, 9, 'exported nodes + root');
        const markdown = await port.exportMarkdown(main);
        assert(markdown.includes('**You**'), 'Markdown has no speaker labels');
        const archive = await port.exportArchive([main]);
        const again = await port.importArchive(archive, {duplicates: 'copy'});
        same(again.imported.length, 1, 'chats imported from our own archive');
        const copy = track(again.imported[0]);
        const [reexported] = await port.exportConversations([copy]);
        same(reexported.mapping, exported.mapping, 're-exported tree');
        const thread = await port.getThread(copy);
        same(thread.length, 4, 'imported thread');
        same(thread[2].versionCount, 2, 'imported versions');
        await chatSessionStore.setActiveSession(copy);
        same(shown(copy), shown(main), 'imported chat on screen');
        return `${archive.length} byte zip, ${markdown.length} chars of Markdown`;
      },
    ],

    [
      'import a ChatGPT export archive',
      async () => {
        const fixture = require('../fixtures/chatgpt-export/conversations.json');
        const {buildChatGptArchive} = require('../archive');
        const result = await port.importArchive(buildChatGptArchive(fixture), {
          duplicates: 'copy',
        });
        result.imported.forEach(track);
        same(result.imported.length, 5, 'conversations imported');
        const exported = await port.exportConversations(result.imported);
        for (const original of fixture) {
          const match = exported.find(c => c.title === original.title);
          if (original.title === 'New chat') {
            continue;
          }
          same(match, original, `re-export of "${original.title}"`);
        }
        const hits = await port.search('検証');
        assert(hits.length > 0, 'Japanese text not found');
        let kyotoId = '';
        for (const id of result.imported) {
          if ((await port.getMeta(id))?.title.startsWith('Kyoto')) {
            kyotoId = id;
          }
        }
        await chatSessionStore.setActiveSession(kyotoId);
        const thread = await port.getThread(kyotoId);
        await port.switchVersion(kyotoId, thread[1].messageId, 'previous');
        assert(
          shown(kyotoId)[1].startsWith('Late November'),
          'imported version switch',
        );
        return `5 chats, ${exported.reduce((n, c) => n + Object.keys(c.mapping).length, 0)} nodes, re-export identical`;
      },
    ],

    ['search latency over 5,001 messages', searchLatency],

    [
      'delete one, then bulk delete',
      async () => {
        chatSessionStore.resetActiveSession();
        const store = await port.store();
        const first = made.shift()!;
        await port.deleteSessions([first]);
        assert(!(await port.getMeta(first)), 'meta survived a delete');
        const rest = made.splice(0);
        await port.deleteSessions(rest);
        for (const id of rest) {
          assert(!(await port.getMeta(id)), `meta of ${id} survived`);
          same((await store.getAllNodes(id)).length, 0, 'nodes survived');
          assert(
            !(await chatSessionRepository.getSessionById(id)),
            'upstream rows survived',
          );
        }
        same(
          (await port.search('gulbenkian', {includeParked: true})).length,
          0,
          'index rows survived',
        );
        const stats = await store.stats();
        return `${rest.length + 1} chats deleted; ${stats.sessions} chats and ${stats.nodes} nodes remain`;
      },
    ],
  ];
}

/** Runs every check in order and writes the report to the documents folder. */
export async function runStoreChecks(
  log: (line: string) => void,
): Promise<CheckReport> {
  const report: CheckReport = {
    platform: `${Platform.OS} ${Platform.Version}`,
    startedAt: new Date().toISOString(),
    finished: false,
    passed: 0,
    failed: 0,
    results: [],
  };
  const save = () =>
    RNFS.writeFile(
      `${RNFS.DocumentDirectoryPath}/${REPORT_FILE}`,
      JSON.stringify(report, null, 1),
      'utf8',
    ).catch(() => undefined);

  for (const [name, run] of buildChecks()) {
    const start = performance.now();
    let result: CheckResult;
    try {
      const detail = await run();
      result = {name, ok: true, detail, ms: performance.now() - start};
      report.passed++;
    } catch (error: any) {
      result = {
        name,
        ok: false,
        detail: String(error?.message ?? error),
        ms: performance.now() - start,
      };
      report.failed++;
    }
    report.results.push(result);
    const line = `${result.ok ? 'PASS' : 'FAIL'} ${name} (${result.ms.toFixed(0)} ms) ${result.detail}`;
    log(line);
    console.log(`[store-dev] ${line}`);
    await save();
  }
  report.finished = true;
  await save();
  const summary = `${report.passed} passed, ${report.failed} failed`;
  log(summary);
  console.log(`[store-dev] DONE ${summary}`);
  return report;
}
