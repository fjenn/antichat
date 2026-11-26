/* eslint-disable no-bitwise */
/**
 * Starter prompts for the empty chat (H10): a static list that rotates, so
 * the empty state feels fresh without a generation. Every starter works
 * offline on the smallest model; none needs search, files or images.
 *
 * `label` is the chip text (M1's locale file may translate it by `id`),
 * `prompt` is what lands in the composer.
 */

export type StarterCategory =
  | 'write'
  | 'learn'
  | 'plan'
  | 'code'
  | 'think'
  | 'fun';

export interface Starter {
  id: string;
  category: StarterCategory;
  label: string;
  prompt: string;
}

export const STARTERS: readonly Starter[] = [
  {
    id: 'write-email',
    category: 'write',
    label: 'Write a polite email',
    prompt:
      'Help me write a polite email to reschedule a meeting to next week.',
  },
  {
    id: 'write-message',
    category: 'write',
    label: 'Reply to a message',
    prompt:
      'Help me reply to a message. I will paste it and tell you the tone I want.',
  },
  {
    id: 'write-improve',
    category: 'write',
    label: 'Improve my writing',
    prompt:
      'I will paste a text. Make it clearer and more concise without changing its meaning.',
  },
  {
    id: 'write-toast',
    category: 'write',
    label: 'Write a short toast',
    prompt: "Write a short, warm toast for a friend's birthday dinner.",
  },
  {
    id: 'learn-explain',
    category: 'learn',
    label: 'Explain a concept simply',
    prompt:
      'Explain how compound interest works in simple terms, with one small example.',
  },
  {
    id: 'learn-quiz',
    category: 'learn',
    label: 'Quiz me on a topic',
    prompt:
      'Quiz me on world capitals, one question at a time, and tell me how I did.',
  },
  {
    id: 'learn-language',
    category: 'learn',
    label: 'Practise a language',
    prompt:
      "Let's practise Spanish. Talk to me in simple Spanish and correct my mistakes.",
  },
  {
    id: 'learn-summary',
    category: 'learn',
    label: 'Summarise a text',
    prompt: 'I will paste a text. Summarise it in five bullet points.',
  },
  {
    id: 'plan-trip',
    category: 'plan',
    label: 'Plan a weekend trip',
    prompt:
      'Plan a relaxed weekend city trip for two, with a rough schedule for each day.',
  },
  {
    id: 'plan-meals',
    category: 'plan',
    label: 'Plan meals for the week',
    prompt: 'Plan five quick weeknight dinners and a shopping list for them.',
  },
  {
    id: 'plan-workout',
    category: 'plan',
    label: 'Make a workout plan',
    prompt:
      'Make a simple three-day workout plan for a beginner with no equipment.',
  },
  {
    id: 'plan-day',
    category: 'plan',
    label: 'Organise my day',
    prompt:
      'Help me organise my day. I will list my tasks and you put them in a sensible order.',
  },
  {
    id: 'code-explain',
    category: 'code',
    label: 'Explain some code',
    prompt: 'I will paste some code. Explain what it does step by step.',
  },
  {
    id: 'code-script',
    category: 'code',
    label: 'Write a small script',
    prompt:
      'Write a Python script that renames all files in a folder to lowercase.',
  },
  {
    id: 'code-regex',
    category: 'code',
    label: 'Build a regex',
    prompt:
      'Write a regular expression that matches a date like 2026-11-24, and explain it.',
  },
  {
    id: 'code-formula',
    category: 'code',
    label: 'Help with a spreadsheet formula',
    prompt:
      'Write a spreadsheet formula that sums column B only where column A says "paid".',
  },
  {
    id: 'think-decide',
    category: 'think',
    label: 'Help me decide',
    prompt: 'Help me decide between two options. Ask me a few questions first.',
  },
  {
    id: 'think-proscons',
    category: 'think',
    label: 'Weigh pros and cons',
    prompt:
      'List the pros and cons of working from home compared with working in an office.',
  },
  {
    id: 'think-interview',
    category: 'think',
    label: 'Prepare for an interview',
    prompt:
      'Ask me five common job interview questions, one at a time, and give feedback on my answers.',
  },
  {
    id: 'think-brainstorm',
    category: 'think',
    label: 'Brainstorm ideas',
    prompt: 'Brainstorm ten name ideas for a small neighbourhood coffee shop.',
  },
  {
    id: 'fun-story',
    category: 'fun',
    label: 'Tell me a story',
    prompt: 'Tell me a short bedtime story about a fox who learns to sail.',
  },
  {
    id: 'fun-fact',
    category: 'fun',
    label: 'Surprise me with a fact',
    prompt: 'Tell me a surprising fact about the ocean and why it is true.',
  },
  {
    id: 'fun-riddle',
    category: 'fun',
    label: 'Give me a riddle',
    prompt:
      'Give me a riddle and wait for my answer before revealing the solution.',
  },
  {
    id: 'fun-recipe',
    category: 'fun',
    label: 'Cook with what I have',
    prompt:
      'Suggest a meal I can cook with eggs, rice and whatever vegetables I name.',
  },
];

/** Days since the epoch in local time: the default rotation seed. */
export function daySeed(now: Date = new Date()): number {
  return Math.floor(
    (now.getTime() - now.getTimezoneOffset() * 60000) / 86400000,
  );
}

// Small deterministic PRNG (mulberry32) so a seed always gives the same set.
const prng = (seed: number) => {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
};

/**
 * `count` starters for the empty state, each from a different category while
 * categories last. The same seed returns the same starters, so the row does
 * not reshuffle while the user looks at it; the default seed changes daily.
 */
export function pickStarters(
  count = 4,
  seed: number = daySeed(),
  pool: readonly Starter[] = STARTERS,
): Starter[] {
  const random = prng(seed);
  const shuffled = [...pool];
  for (let i = shuffled.length - 1; i > 0; i--) {
    const j = Math.floor(random() * (i + 1));
    [shuffled[i], shuffled[j]] = [shuffled[j], shuffled[i]];
  }
  const picked: Starter[] = [];
  const used = new Set<StarterCategory>();
  for (const starter of shuffled) {
    if (picked.length === count) {
      break;
    }
    if (!used.has(starter.category)) {
      used.add(starter.category);
      picked.push(starter);
    }
  }
  for (const starter of shuffled) {
    if (picked.length === count) {
      break;
    }
    if (!picked.includes(starter)) {
      picked.push(starter);
    }
  }
  return picked;
}
