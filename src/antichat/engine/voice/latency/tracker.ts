/**
 * Latency budget of a voice turn: from the end of the user's speech to the
 * first audio of the answer, split into the four stages that add up to it.
 *
 *   speechEnd ──endpointing──▶ endpoint ──stt──▶ sttFinal
 *             ──llm (first sentence)──▶ firstSentence ──tts──▶ firstAudio
 *
 * With speculative generation, the transcript and the first sentence can be
 * ready before the endpoint; those stages then cost 0 and the endpoint wait
 * is the floor.
 */

export type LatencyMark =
  | 'speechEnd'
  | 'endpoint'
  | 'sttFinal'
  | 'firstToken'
  | 'firstSentence'
  | 'firstAudio';

export interface LatencyBreakdown {
  endpointingMs: number;
  sttMs: number;
  /** Request start to the first complete sentence of the answer. */
  llmFirstSentenceMs: number;
  /** First sentence handed to the voice until audio starts. */
  ttsFirstAudioMs: number;
  /** End of speech to first audio. */
  totalMs: number;
}

export interface TurnLatency extends LatencyBreakdown {
  turn: number;
  speculation: 'off' | 'adopted' | 'discarded' | 'none';
  /** Time to the first token, inside `llmFirstSentenceMs`. */
  firstTokenMs: number | null;
  marks: Partial<Record<LatencyMark, number>>;
}

export interface BargeInLatency {
  /** Speech onset until the detector called it a barge-in (audio time). */
  detectMs: number;
  /** Detection until the speaker reported silence. */
  stopMs: number;
}

export function breakdown(
  marks: Partial<Record<LatencyMark, number>>,
): LatencyBreakdown | null {
  const {speechEnd, endpoint, sttFinal, firstSentence, firstAudio} = marks;
  if (
    speechEnd === undefined ||
    endpoint === undefined ||
    sttFinal === undefined ||
    firstSentence === undefined ||
    firstAudio === undefined
  ) {
    return null;
  }
  const sttDone = Math.max(endpoint, sttFinal);
  const sentenceDone = Math.max(sttDone, firstSentence);
  return {
    endpointingMs: endpoint - speechEnd,
    sttMs: sttDone - endpoint,
    llmFirstSentenceMs: sentenceDone - sttDone,
    ttsFirstAudioMs: Math.max(0, firstAudio - sentenceDone),
    totalMs: firstAudio - speechEnd,
  };
}

export function percentile(values: readonly number[], p: number): number {
  if (values.length === 0) {
    return NaN;
  }
  const sorted = [...values].sort((a, b) => a - b);
  const rank = (sorted.length - 1) * p;
  const low = Math.floor(rank);
  const high = Math.ceil(rank);
  return sorted[low]! + (sorted[high]! - sorted[low]!) * (rank - low);
}

export type LatencySummary = Record<
  keyof LatencyBreakdown,
  {p50: number; p90: number}
> & {
  turns: number;
};

export class LatencyTracker {
  readonly turns: TurnLatency[] = [];
  readonly bargeIns: BargeInLatency[] = [];
  private marks: Partial<Record<LatencyMark, number>> = {};
  private speculation: TurnLatency['speculation'] = 'off';
  private counter = 0;

  begin(): void {
    this.marks = {};
    this.speculation = 'off';
  }

  /** Records the first occurrence of `name` in the current turn. */
  mark(name: LatencyMark, atMs: number): void {
    this.marks[name] ??= atMs;
  }

  setSpeculation(outcome: TurnLatency['speculation']): void {
    this.speculation = outcome;
  }

  /** Closes the turn once `firstAudio` is marked; null if a mark is missing. */
  complete(): TurnLatency | null {
    const parts = breakdown(this.marks);
    if (!parts) {
      return null;
    }
    const {firstToken, endpoint, sttFinal} = this.marks;
    const turn: TurnLatency = {
      turn: ++this.counter,
      speculation: this.speculation,
      firstTokenMs:
        firstToken === undefined
          ? null
          : Math.max(0, firstToken - Math.max(endpoint!, sttFinal!)),
      marks: {...this.marks},
      ...parts,
    };
    this.turns.push(turn);
    this.marks = {};
    return turn;
  }

  recordBargeIn(entry: BargeInLatency): void {
    this.bargeIns.push(entry);
  }

  summary(turns: readonly TurnLatency[] = this.turns): LatencySummary {
    const stat = (key: keyof LatencyBreakdown) => {
      const values = turns.map(t => t[key]);
      return {
        p50: Math.round(percentile(values, 0.5)),
        p90: Math.round(percentile(values, 0.9)),
      };
    };
    return {
      turns: turns.length,
      endpointingMs: stat('endpointingMs'),
      sttMs: stat('sttMs'),
      llmFirstSentenceMs: stat('llmFirstSentenceMs'),
      ttsFirstAudioMs: stat('ttsFirstAudioMs'),
      totalMs: stat('totalMs'),
    };
  }
}
