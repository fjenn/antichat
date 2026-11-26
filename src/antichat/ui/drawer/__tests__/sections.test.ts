import type {ConversationView} from '../../../contracts';
import {makeSeedConversations} from '../dev/seed';
import {parseChatGptConversation} from '../../../engine/store/chatgpt';
import {buildDrawerItems, groupOf, type SectionLabels} from '../sections';

const DAY = 24 * 60 * 60 * 1000;
const NOW = new Date(2026, 10, 24, 15, 0, 0).getTime();

const labels: SectionLabels = {
  pinned: 'Pinned',
  today: 'Today',
  yesterday: 'Yesterday',
  previous7Days: 'Previous 7 days',
  previous30Days: 'Previous 30 days',
  month: month => `M${month + 1}`,
};

function chat(id: string, age: number, more: Partial<ConversationView> = {}) {
  return {
    id,
    title: id,
    updatedAt: NOW - age,
    createdAt: NOW - age,
    pinned: false,
    archived: false,
    temporary: false,
    locked: false,
    ...more,
  } satisfies ConversationView;
}

const outline = (items: ReturnType<typeof buildDrawerItems>) =>
  items.map(item =>
    item.kind === 'header' ? `# ${item.title}` : item.conversation.id,
  );

describe('drawer sections', () => {
  it('groups by day, then month of this year, then year', () => {
    const items = buildDrawerItems(
      [
        chat('now', 0),
        chat('this-morning', 14 * 60 * 60 * 1000),
        chat('yesterday', 1 * DAY),
        chat('five-days', 5 * DAY),
        chat('seven-days', 7 * DAY),
        chat('three-weeks', 21 * DAY),
        chat('september', 70 * DAY),
        chat('march', 250 * DAY),
        chat('last-year', 400 * DAY),
        chat('older', 800 * DAY),
      ],
      NOW,
      labels,
    );
    expect(outline(items)).toEqual([
      '# Today',
      'now',
      'this-morning',
      '# Yesterday',
      'yesterday',
      '# Previous 7 days',
      'five-days',
      'seven-days',
      '# Previous 30 days',
      'three-weeks',
      '# M9',
      'september',
      '# M3',
      'march',
      '# 2025',
      'last-year',
      '# 2024',
      'older',
    ]);
  });

  it('puts pinned chats first, whatever their age', () => {
    const items = buildDrawerItems(
      [chat('a', 0), chat('b', 3 * DAY, {pinned: true}), chat('c', 90 * DAY)],
      NOW,
      labels,
    );
    expect(outline(items)).toEqual([
      '# Pinned',
      'b',
      '# Today',
      'a',
      '# M8',
      'c',
    ]);
  });

  it('leaves out archived, temporary and hidden chats and empty groups', () => {
    const items = buildDrawerItems(
      [
        chat('kept', 0),
        chat('archived', 0, {archived: true}),
        chat('temporary', 0, {temporary: true}),
        chat('deleting', 1 * DAY),
        chat('pinned-deleting', 2 * DAY, {pinned: true}),
      ],
      NOW,
      labels,
      new Set(['deleting', 'pinned-deleting']),
    );
    expect(outline(items)).toEqual(['# Today', 'kept']);
    expect(buildDrawerItems([], NOW, labels)).toEqual([]);
  });

  it('gives every item a unique key', () => {
    const items = buildDrawerItems(
      [chat('a', 0), chat('b', 40 * DAY), chat('c', 41 * DAY)],
      NOW,
      labels,
    );
    expect(new Set(items.map(item => item.key)).size).toBe(items.length);
  });

  it('counts calendar days, not 24-hour spans', () => {
    // 15:00 now; 23:30 the evening before is "yesterday", 16 hours ago.
    expect(groupOf(NOW - 15.5 * 60 * 60 * 1000, NOW, labels).key).toBe(
      'yesterday',
    );
    expect(groupOf(NOW + 60_000, NOW, labels).key).toBe('today');
  });
});

describe('seed history', () => {
  const seed = makeSeedConversations(2000, {now: NOW});

  it('builds 2,000 distinct chats the store can import', () => {
    expect(seed).toHaveLength(2000);
    expect(new Set(seed.map(c => c.conversation_id)).size).toBe(2000);
    const parsed = parseChatGptConversation(seed[1234]);
    expect(parsed?.title).toBeTruthy();
    expect(parsed!.nodes.length).toBeGreaterThanOrEqual(2);
    expect(parsed!.nodes.every(node => node.onPath)).toBe(true);
    expect(parsed!.updatedAt).toBeLessThanOrEqual(NOW);
  });

  it('is the same every time and spreads over two years', () => {
    expect(makeSeedConversations(2000, {now: NOW})).toEqual(seed);
    const ages = seed.map(c => NOW - (c.update_time as number) * 1000);
    expect(Math.min(...ages)).toBeLessThan(DAY);
    expect(Math.max(...ages)).toBeGreaterThan(700 * DAY);
    expect(seed.filter(c => 'antichat' in c)).toHaveLength(5);
  });

  it('groups 2,000 chats for the drawer in a few milliseconds', () => {
    const chats = seed
      .map((c, index) =>
        chat(`c${index}`, NOW - (c.update_time as number) * 1000),
      )
      .sort((a, b) => b.updatedAt - a.updatedAt);
    // Best of several runs: machine load can slow one run, but not all of
    // them, so the 50 ms budget keeps its meaning.
    let took = Infinity;
    let items = buildDrawerItems(chats, NOW, labels);
    for (let run = 0; run < 7; run++) {
      const started = performance.now();
      items = buildDrawerItems(chats, NOW, labels);
      took = Math.min(took, performance.now() - started);
    }
    expect(items.filter(item => item.kind === 'chat')).toHaveLength(2000);
    expect(items.filter(item => item.kind === 'header').length).toBeGreaterThan(
      6,
    );
    expect(took).toBeLessThan(50);
  });
});
