/**
 * Audio files: the hook the voice engine fills in.
 *
 * The files engine does not transcribe. It asks whoever registered here
 * (M11's speech recogniser, when it exposes file transcription) and treats
 * the transcript like any other document: stuffed when short, searched when
 * long, with time ranges in place of pages.
 */
export interface TranscriptSegment {
  startSec: number;
  endSec: number;
  text: string;
}

export interface AudioTranscript {
  language?: string;
  durationSec: number;
  segments: TranscriptSegment[];
}

export interface AudioTranscriber {
  /** False when no speech model is installed or the device cannot run it. */
  available(): boolean | Promise<boolean>;
  /** Longest audio it accepts, seconds. */
  maxDurationSec?: number;
  transcribe(
    uri: string,
    options: {
      signal?: AbortSignal;
      onProgress?: (fraction: number) => void;
      language?: string;
    },
  ): Promise<AudioTranscript>;
}

let transcriber: AudioTranscriber | null = null;

/** Called by the voice engine once it can transcribe files. */
export function setAudioTranscriber(next: AudioTranscriber | null): void {
  transcriber = next;
}

export function getAudioTranscriber(): AudioTranscriber | null {
  return transcriber;
}

const clock = (seconds: number) => {
  const whole = Math.floor(seconds);
  return `${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, '0')}`;
};

/** One "page" per minute of speech, titled with its time range. */
export function transcriptPages(
  transcript: AudioTranscript,
): Array<{page: number; title: string; text: string}> {
  const pages = new Map<number, string[]>();
  for (const segment of transcript.segments) {
    const minute = Math.floor(segment.startSec / 60);
    pages.set(minute, [...(pages.get(minute) ?? []), segment.text.trim()]);
  }
  return [...pages.entries()]
    .sort((a, b) => a[0] - b[0])
    .map(([minute, texts]) => ({
      page: minute + 1,
      title: `${clock(minute * 60)}–${clock(minute * 60 + 60)}`,
      text: texts.join(' '),
    }));
}
