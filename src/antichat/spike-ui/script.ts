/**
 * Scripted answer for the scroll/streaming spike: about 600 words with every
 * block type the chat must render half-built (paragraphs, lists, a table, a
 * code block, inline and block LaTeX, links).
 */
// § stands in for a backtick, which a template literal cannot hold unescaped.
export const SCRIPTED_ANSWER =
  String.raw`Here is a practical way to think about **binary search**, with the pieces you asked for.

## The idea

Binary search finds a value in a *sorted* list by halving the range it still has to look at. Each step compares the middle element with the target and throws away the half that cannot contain it. Because the range shrinks by a factor of two every time, a list of a million items needs at most twenty comparisons, which is why the technique shows up everywhere from database indexes to version-control tools such as [git bisect](https://git-scm.com/docs/git-bisect).

The number of steps for a list of length $n$ is bounded by

$$
T(n) = \lfloor \log_2 n \rfloor + 1
$$

so doubling the input adds exactly one step. For comparison, a linear scan needs $\frac{n}{2}$ steps on average.

## When to use it

1. The data is sorted, or can be sorted once and searched many times.
2. Random access is cheap. Arrays qualify; linked lists do not.
3. You need a boundary rather than an exact match, for example "the first build that fails".

A few things people get wrong:

- Computing the midpoint as §(lo + hi) / 2§ overflows in languages with fixed-width integers.
- Forgetting to shrink the range past the midpoint causes an infinite loop.
- Searching unsorted input silently returns nonsense instead of failing.

## Implementation

§§§python
def binary_search(items: list[int], target: int) -> int:
    """Return the index of target, or -1 when it is absent."""
    lo, hi = 0, len(items) - 1
    while lo <= hi:
        mid = lo + (hi - lo) // 2
        if items[mid] == target:
            return mid
        if items[mid] < target:
            lo = mid + 1
        else:
            hi = mid - 1
    return -1


print(binary_search([2, 3, 5, 7, 11, 13, 17], 11))  # 4
§§§

The loop keeps the invariant that the target, if present, lies between §lo§ and §hi§ inclusive. When the two cross, the range is empty and the search has failed.

## How it compares

| Method | Needs sorted data | Steps for 1,000,000 items | Extra memory |
|:--|:-:|--:|:-:|
| Linear scan | No | up to 1,000,000 | none |
| Binary search | Yes | 20 | none |
| Hash table | No | about 1 | $O(n)$ |
| B-tree index | Yes | 3 to 4 page reads | $O(n)$ |

Hash tables are faster for exact matches, but they cannot answer range questions such as "everything between 40 and 60", and they give up ordering entirely. A sorted array with binary search gives both, at the price of slow inserts.

## A variant worth knowing

To find the *leftmost* position where a value could be inserted, keep going after a match instead of returning:

§§§ts
function lowerBound(items: number[], target: number): number {
  let lo = 0;
  let hi = items.length;
  while (lo < hi) {
    const mid = (lo + hi) >>> 1;
    if (items[mid] < target) lo = mid + 1;
    else hi = mid;
  }
  return lo;
}
§§§

This half-open form, with §hi§ one past the end, is the one most standard libraries use, including [Python's bisect module](https://docs.python.org/3/library/bisect.html) and C++ §std::lower_bound§. It has fewer off-by-one traps because the range §[lo, hi)§ is empty exactly when §lo == hi§.

## Summary

Binary search trades a one-time sort for logarithmic lookups: $O(\log n)$ time and $O(1)$ space. Reach for it whenever the data is ordered and you ask "where does this belong?" more often than you change the data. If you want, I can walk through the proof of the loop invariant or show the same idea applied to searching over an answer space.`.replace(
    /§/g,
    '`',
  );

/** Short answer used for the "previous reply did not overflow" cases. */
export const SHORT_ANSWER =
  'Sure. The capital of France is **Paris**, on the Seine in the north of the country.';

/** A longer user question (three lines in the bubble). */
export const USER_QUESTIONS = [
  'Explain binary search with code, a comparison table and the maths.',
  'What is the capital of France?',
  'Can you also show the half-open variant and tell me which standard libraries use it? Keep the table.',
];

/**
 * Splits text into pieces shaped like model tokens: a leading space or
 * newline run glued to up to five following characters, punctuation alone.
 */
export function tokenize(text: string): string[] {
  return text.match(/\s*(?:[A-Za-z0-9]{1,5}|[^\sA-Za-z0-9])|\s+$/g) ?? [];
}
