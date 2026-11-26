/**
 * Scripted answers for the fake chat. Between them they contain every
 * markdown construct the thread has to render while it is still arriving:
 * headings, bold, lists, a table, a code block, inline and block maths, a
 * quote and a link.
 */

const OVERVIEW = `Here's a short plan you can adjust.

## The idea

A **transformer** reads the whole sentence at once and decides, for every word, which other words matter most. That step is called *attention*.

1. Split the text into tokens.
2. Turn each token into a vector.
3. Let every vector look at the others and mix in what is relevant.
4. Repeat for a few layers, then predict the next token.

> The trick is that step 3 runs for all tokens in parallel.

| Part | What it does | Cost |
| --- | --- | --- |
| Embedding | Token to vector | Low |
| Attention | Mixes context | High |
| Feed-forward | Refines each token | Medium |

The attention weight between two tokens is

$$\\alpha_{ij} = \\frac{e^{q_i \\cdot k_j}}{\\sum_l e^{q_i \\cdot k_l}}$$

so every row of weights sums to $1$.

Want the same thing as a diagram, or a version for a ten-year-old?`;

const CODE = `That test fails now and then because it reads the clock twice.

\`\`\`ts
// Before: two calls, and midnight can fall between them
const start = new Date();
const end = addDays(new Date(), 1);

// After: one reading
const now = new Date();
const start = now;
const end = addDays(now, 1);
\`\`\`

Two more things worth doing:

- Freeze time in the test with \`jest.useFakeTimers()\`.
- Assert on the **difference** between the dates, not on the dates themselves.

The [Jest timer docs](https://jestjs.io/docs/timer-mocks) cover the details.`;

const SHORT = `Sure. Three options, shortest first:

- **Warm:** "Happy birthday, Mum. Thank you for everything, today and always."
- **Light:** "Another year wiser, and still the best cook I know."
- **Longer:** tell me one memory you share and I'll build it around that.`;

export const FAKE_REASONING =
  'The user wants something practical. Start with the core idea, then steps, ' +
  'then a compact table. Keep the maths to one formula and end with an offer ' +
  'to adapt it.';

/** Picks a script from the prompt so different chats look different. */
export function fakeAnswerFor(prompt: string): string {
  const text = prompt.toLowerCase();
  if (/(test|code|bug|regex|jest|function|script)/.test(text)) {
    return CODE;
  }
  if (/(birthday|message|note|email|letter|gift)/.test(text)) {
    return SHORT;
  }
  return OVERVIEW;
}

/**
 * Splits text the way a tokenizer roughly would: words keep their leading
 * space, punctuation and newlines come as their own pieces.
 */
export function fakeTokens(text: string): string[] {
  return text.match(/\s*[^\s]{1,6}|\s+$/g) ?? [];
}

/** A title the way the title generator would write one: short, no full stop. */
export function fakeTitleFor(prompt: string): string {
  const words = prompt
    .replace(/[\n\r]+/g, ' ')
    .trim()
    .split(/\s+/)
    .slice(0, 6);
  const title = words.join(' ').replace(/[.,;:!?]+$/, '');
  return title.length > 36 ? `${title.slice(0, 35).trimEnd()}…` : title;
}
