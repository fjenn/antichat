/**
 * Strict search budgets per context size. Everything the search layer puts
 * in front of the model is bounded here, so a result block can never push the
 * conversation out of a small window. Evidence stays at or under roughly a
 * quarter of the window (the ChatGPT audit's recipe allows up to 40 %; a 2B
 * model reads less and answers better).
 */
import type {DeviceClass} from '../prompt/types';

export interface SearchBudget {
  /** Queries per search step. */
  queries: number;
  /** Sources listed in the result block. */
  results: number;
  /** Characters of a result snippet. */
  snippetChars: number;
  /** Pages fetched and read per search step. */
  pages: number;
  /** Chunks kept per read page. */
  chunksPerPage: number;
  /** Approximate tokens per chunk. */
  chunkTokens: number;
  /** Ceiling for all evidence text of one result block, in tokens. */
  evidenceTokens: number;
  /** Ceiling for one `read_url` result, in tokens. */
  pageTokens: number;
  /** Wall-clock limit for reading pages after the search, ms. */
  readDeadlineMs: number;
}

const TABLE: Array<{upTo: number; budget: SearchBudget}> = [
  {
    upTo: 4096,
    budget: {
      queries: 1,
      results: 3,
      snippetChars: 220,
      pages: 1,
      chunksPerPage: 2,
      chunkTokens: 160,
      evidenceTokens: 600,
      pageTokens: 700,
      readDeadlineMs: 3500,
    },
  },
  {
    upTo: 8192,
    budget: {
      queries: 1,
      results: 5,
      snippetChars: 280,
      pages: 2,
      chunksPerPage: 2,
      chunkTokens: 220,
      evidenceTokens: 1500,
      pageTokens: 1500,
      readDeadlineMs: 4000,
    },
  },
  {
    upTo: 16384,
    budget: {
      queries: 2,
      results: 6,
      snippetChars: 300,
      pages: 3,
      chunksPerPage: 3,
      chunkTokens: 250,
      evidenceTokens: 3000,
      pageTokens: 3000,
      readDeadlineMs: 5000,
    },
  },
  {
    upTo: Infinity,
    budget: {
      queries: 3,
      results: 8,
      snippetChars: 320,
      pages: 4,
      chunksPerPage: 3,
      chunkTokens: 280,
      evidenceTokens: 5000,
      pageTokens: 5000,
      readDeadlineMs: 6000,
    },
  },
];

export function searchBudgetFor(
  nCtx = 8192,
  deviceClass: DeviceClass = 'B',
): SearchBudget {
  const row =
    TABLE.find(entry => nCtx <= entry.upTo) ?? TABLE[TABLE.length - 1];
  const budget = {...row.budget};
  if (deviceClass === 'A') {
    // 4 GB phones: one query, snippets plus at most one page.
    budget.queries = 1;
    budget.pages = Math.min(budget.pages, 1);
    budget.results = Math.min(budget.results, 3);
  }
  return budget;
}

/** Rough token count for budgeting web text (mixed scripts, URLs). */
export const approxTokens = (text: string): number =>
  Math.ceil(text.length / 3.6);

/** Cut text to a token budget at a sentence or line end. */
export function clipToTokens(text: string, tokens: number): string {
  const maxChars = Math.floor(tokens * 3.6);
  if (text.length <= maxChars) {
    return text;
  }
  const cut = text.slice(0, maxChars);
  const stop = Math.max(
    cut.lastIndexOf('. '),
    cut.lastIndexOf('\n'),
    cut.lastIndexOf('。'),
  );
  return (
    (stop > maxChars * 0.6 ? cut.slice(0, stop + 1) : cut).trimEnd() + ' …'
  );
}
