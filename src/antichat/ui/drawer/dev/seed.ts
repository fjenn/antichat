/**
 * Test histories. `makeSeedConversations(2000)` builds a believable history
 * of that many chats in ChatGPT's export shape, which the conversation store
 * imports as it would a real export. Deterministic: the same count gives the
 * same chats (relative to `now`), so screenshots and timings can be compared.
 */
const DAY = 24 * 60 * 60 * 1000;

const SUBJECTS = [
  'Weekend trip to Lisbon',
  'Sourdough starter schedule',
  'Explain transformers simply',
  'Cover letter for a design role',
  'Fix a flaky Jest test',
  'Birthday message for Mum',
  'Compare two phone plans',
  'Spanish practice: ordering food',
  'Summary of the meeting notes',
  'Why is the sky blue at noon and red at sunset?',
  'Budget for the kitchen renovation',
  'Regex for dates',
  'Names for a grey cat',
  'Half-marathon training plan',
  'How do tides work',
  'Gift ideas under 30 euros',
  'Packing list for a hiking week',
  'Rewrite this email politely',
  'Meal plan without dairy',
  'What to ask a landlord',
  'Chord progression for a slow song',
  'Explain compound interest',
  'Plot outline for a short story',
  'Stretching routine for desk work',
];

const DETAILS = [
  'with a tight budget',
  'for beginners',
  'step by step',
  'in under an hour',
  'for a family of four',
  'without special tools',
  'for next month',
  'the short version',
];

const ANSWERS = [
  'Here is a simple way to think about it. Start with the smallest piece that works, check it, and only then add the next one.',
  'Three things matter most: the order you do them in, how long each takes, and what you can skip without regret.',
  'A good first step is to write down what you already know. The gaps show up quickly once it is on the page.',
  'The usual mistake is doing everything at once. Split it into mornings and evenings and it becomes manageable.',
  'It depends on two numbers. Once you have both, the rest is arithmetic, and I can walk through it with you.',
];

/** Small deterministic generator (a linear congruential one is plenty). */
function random(seed: number): () => number {
  let state = seed % 4294967296;
  return () => {
    state = (state * 1664525 + 1013904223) % 4294967296;
    return state / 4294967296;
  };
}

/** Age of chat `index` of `count`: dense recently, thinning over two years. */
function ageOf(index: number, count: number, next: () => number): number {
  const position = index / Math.max(1, count - 1);
  // Cubic: a third of the chats fall in the last three weeks.
  return Math.pow(position, 3) * 730 * DAY + next() * 0.4 * DAY;
}

export interface SeedOptions {
  now?: number;
  /** Prefix of every `conversation_id`; change it to add a second batch. */
  batch?: string;
  /** Every n-th chat is pinned (0: none). */
  pinEvery?: number;
}

export function makeSeedConversations(
  count: number,
  options: SeedOptions = {},
): Record<string, unknown>[] {
  const now = options.now ?? Date.now();
  const batch = options.batch ?? 'seed';
  const pinEvery = options.pinEvery ?? 400;
  const next = random(count * 7919 + 17);
  const conversations: Record<string, unknown>[] = [];
  for (let index = 0; index < count; index++) {
    const subject = SUBJECTS[index % SUBJECTS.length];
    const detail = DETAILS[Math.floor(next() * DETAILS.length)];
    const title =
      index < SUBJECTS.length ? subject : `${subject} ${detail} (${index + 1})`;
    const updated = now - ageOf(index, count, next);
    const turns = 1 + Math.floor(next() * 3);
    const id = `${batch}-${index}`;
    const mapping: Record<string, unknown> = {
      [`${id}-root`]: {
        id: `${id}-root`,
        message: null,
        parent: null,
        children: [`${id}-m0`],
      },
    };
    const total = turns * 2;
    for (let m = 0; m < total; m++) {
      const role = m % 2 === 0 ? 'user' : 'assistant';
      const text =
        role === 'user'
          ? m === 0
            ? `${subject} ${detail}?`
            : `And what about ${DETAILS[(index + m) % DETAILS.length]}?`
          : `${ANSWERS[(index + m) % ANSWERS.length]} (${subject.toLowerCase()}, note ${index + 1})`;
      const stamp = (updated - (total - m) * 20_000) / 1000;
      mapping[`${id}-m${m}`] = {
        id: `${id}-m${m}`,
        message: {
          id: `${id}-m${m}`,
          author: {role},
          create_time: stamp,
          content: {content_type: 'text', parts: [text]},
          status: 'finished_successfully',
        },
        parent: m === 0 ? `${id}-root` : `${id}-m${m - 1}`,
        children: m + 1 < total ? [`${id}-m${m + 1}`] : [],
      };
    }
    conversations.push({
      title,
      create_time: (updated - 60_000) / 1000,
      update_time: updated / 1000,
      mapping,
      current_node: `${id}-m${total - 1}`,
      conversation_id: id,
      ...(pinEvery > 0 && index % pinEvery === 3
        ? {antichat: {pinned: true}}
        : null),
    });
  }
  return conversations;
}

/**
 * Imports `count` seed chats into the real store, a slice at a time so the
 * screen can show progress. Returns how many were added.
 */
export async function seedHistory(
  count: number,
  onProgress?: (done: number) => void,
  options: SeedOptions = {},
): Promise<number> {
  const {conversationAdapter} = require('../../../adapters/conversation');
  const port = conversationAdapter();
  await port.ready();
  const all = makeSeedConversations(count, options);
  let added = 0;
  const SLICE = 50;
  for (let at = 0; at < all.length; at += SLICE) {
    const result = await port.importConversations(all.slice(at, at + SLICE));
    added += result.imported.length;
    onProgress?.(Math.min(all.length, at + SLICE));
  }
  return added;
}
