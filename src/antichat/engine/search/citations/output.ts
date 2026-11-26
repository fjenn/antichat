/**
 * From raw model text to what the UI draws: clean text, pill positions and
 * the Sources list. One call after the answer (and, for a live preview, on
 * every streamed chunk with `ground: false`).
 *
 * Pipeline: fold marker variants → turn raw URLs of known sources into
 * markers → drop markers that name no source → deterministic grounding
 * check → segments, pills and the Sources list (cited first, then the rest).
 */
import {hostOf, normalizeUrl} from '../html';
import {applyGrounding, attachCitations} from './grounding';
import {
  linkifyKnownUrls,
  normalizeMarkers,
  validateMarkers,
  type Citation,
} from './markers';
import {
  peekRegistry,
  type RegisteredSource,
  type SourceRegistry,
} from './registry';
import type {ToolImage} from '../../tools/types';

export interface CitationPill {
  /** Source numbers behind the pill, first one named on it. */
  sources: number[];
  /** Site shown on the pill, e.g. "bbc.co.uk". */
  label: string;
  /** "+N" count when the pill groups several sources. */
  extra: number;
  url: string;
}

export type AnswerSegment =
  | {type: 'text'; text: string}
  | {type: 'citation'; pill: CitationPill};

export interface SourceListItem {
  n: number;
  title: string;
  url: string;
  site: string;
  snippet?: string;
  publishedAt?: string;
  favicon?: string;
  /** In the answer's pills. Cited sources come first in the sheet. */
  cited: boolean;
  /** The page itself was read. */
  fetched: boolean;
}

export interface CitedAnswer {
  /** Text with canonical `[n]` markers left in place (stored form). */
  text: string;
  /** Text with the markers removed (copy, read aloud, share). */
  plainText: string;
  segments: AnswerSegment[];
  citations: Citation[];
  /** Cited first (in order of first use), then "More". */
  sources: SourceListItem[];
  images: ToolImage[];
  stats: {
    /** Markers the model wrote (after folding variants). */
    written: number;
    /** Numbers that named no source. */
    outOfRange: number;
    /** Cited sentences checked against their sources. */
    checked: number;
    /** Sentences whose marker was removed by the grounding check. */
    ungrounded: number;
    /** Distinct sources cited in the final answer. */
    distinctSources: number;
    /** Markers added by the app for fully supported, uncited sentences. */
    attached: number;
  };
}

export interface BuildOptions {
  /** Run the grounding check (off while streaming). */
  ground?: boolean;
  /**
   * Give an answer that cites nothing the citations its sentences fully
   * support (models that use the sources but skip the markers). Default
   * true; never while streaming.
   */
  attach?: boolean;
}

const toItem = (source: RegisteredSource, cited: boolean): SourceListItem => ({
  n: source.n,
  title: source.title || source.site,
  url: source.url,
  site: source.site || hostOf(source.url),
  snippet: source.snippet,
  publishedAt: source.publishedAt,
  favicon: source.favicon,
  cited,
  fetched: !!source.fetched,
});

export function buildCitedAnswer(
  raw: string,
  registry: SourceRegistry | undefined,
  options: BuildOptions = {},
): CitedAnswer {
  const sources = registry?.sources ?? [];
  if (sources.length === 0) {
    // Nothing was retrieved: bracketed numbers are the model's own (indices,
    // footnotes it made up) and are left exactly as written.
    return {
      text: raw,
      plainText: raw,
      segments: raw ? [{type: 'text', text: raw}] : [],
      citations: [],
      sources: [],
      images: registry?.images ?? [],
      stats: {
        written: 0,
        outOfRange: 0,
        checked: 0,
        ungrounded: 0,
        distinctSources: 0,
        attached: 0,
      },
    };
  }
  const numbers = sources.map(source => source.n);
  let text = normalizeMarkers(raw);
  if (sources.length > 0) {
    text = normalizeMarkers(linkifyKnownUrls(text, sources, normalizeUrl));
  }
  const first = validateMarkers(text, numbers);
  let checked = 0;
  let ungrounded = 0;
  let finalText = first.text;
  let citations = first.citations;
  if (options.ground !== false && registry && first.citations.length > 0) {
    const grounded = applyGrounding(first.text, registry.evidence());
    checked = grounded.checked;
    ungrounded = grounded.uncited;
    const second = validateMarkers(grounded.text, numbers);
    finalText = second.text;
    citations = second.citations;
  }
  let attachedCount = 0;
  if (
    options.ground !== false &&
    options.attach !== false &&
    registry &&
    citations.length === 0
  ) {
    const attached = attachCitations(finalText, registry.evidence());
    if (attached.attached.length > 0) {
      const third = validateMarkers(attached.text, numbers);
      finalText = third.text;
      citations = third.citations;
      attachedCount = attached.attached.length;
    }
  }

  const segments: AnswerSegment[] = [];
  const citedOrder: number[] = [];
  let cursor = 0;
  for (const citation of citations) {
    const marker = `[${citation.sources.join(',')}]`;
    if (citation.location > cursor) {
      segments.push({
        type: 'text',
        text: finalText.slice(cursor, citation.location),
      });
    }
    const lead = registry?.get(citation.sources[0]);
    if (lead) {
      segments.push({
        type: 'citation',
        pill: {
          sources: citation.sources,
          label: lead.site || hostOf(lead.url),
          extra: citation.sources.length - 1,
          url: lead.url,
        },
      });
    }
    citation.sources.forEach(number => {
      if (!citedOrder.includes(number)) {
        citedOrder.push(number);
      }
    });
    cursor = citation.location + marker.length;
  }
  if (cursor < finalText.length) {
    segments.push({type: 'text', text: finalText.slice(cursor)});
  }

  const cited = citedOrder
    .map(number => registry?.get(number))
    .filter((source): source is RegisteredSource => !!source)
    .map(source => toItem(source, true));
  const more = sources
    .filter(source => !citedOrder.includes(source.n))
    .map(source => toItem(source, false));

  const plainText = segments
    .filter(
      (segment): segment is {type: 'text'; text: string} =>
        segment.type === 'text',
    )
    .map(segment => segment.text)
    .join('')
    .replace(/[ \t]+([.,;:!?])/g, '$1')
    .replace(/[ \t]{2,}/g, ' ');

  return {
    text: finalText,
    plainText,
    segments,
    citations,
    sources: [...cited, ...more],
    images: registry?.images ?? [],
    stats: {
      written: first.citations.length,
      outOfRange: first.dropped,
      checked,
      ungrounded,
      distinctSources: citedOrder.length,
      attached: attachedCount,
    },
  };
}

/**
 * The one call the UI makes per answer: `turnId` comes from
 * `prepared.meta.tools.turnId` (and from every tool event of the turn).
 * While tokens arrive, call it with `streaming: true` for live pills; call it
 * once more without when the answer is complete, and store the result.
 */
export function finalizeTurnAnswer(
  turnId: string,
  raw: string,
  options: {streaming?: boolean} = {},
): CitedAnswer {
  return buildCitedAnswer(raw, peekRegistry(turnId), {
    ground: !options.streaming,
    attach: !options.streaming,
  });
}
