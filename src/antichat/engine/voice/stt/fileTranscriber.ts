/**
 * Transcribes an audio attachment: decode → 16 kHz mono → pieces of at most
 * 30 s cut at the quietest point → recogniser, piece by piece, with the text
 * so far as context. Reports progress and can be aborted between pieces.
 */
import {quietestPoint, rms, samplesFor, durationMs} from '../audio/pcm';
import {toSpeechPcm, type WavAudio} from '../audio/wav';
import {voiceError, type VoiceError} from '../types';
import {isPhantom, joinSegments} from './text';
import type {SttAdapter} from './types';

/** Decodes any supported container to float PCM (react-native-audio-api on the phone). */
export interface AudioFileDecoder {
  decode(uri: string): Promise<WavAudio>;
}

export interface FileTranscript {
  text: string;
  language: string;
  durationMs: number;
  /** The file was longer than the cap; only the start was transcribed. */
  truncated: boolean;
  segments: {startMs: number; endMs: number; text: string}[];
}

export interface FileTranscribeOptions {
  language?: string;
  /** Longest piece handed to the recogniser. */
  pieceMs?: number;
  /** Audio beyond this is skipped (gap analysis #60: about 30 minutes). */
  maxDurationMs?: number;
  onProgress?: (fraction: number, textSoFar: string) => void;
  /** Return true to stop after the current piece. */
  isCancelled?: () => boolean;
}

export class FileTranscribeError extends Error {
  constructor(readonly error: VoiceError) {
    super(error.detail ?? error.code);
  }
}

/** Where to cut `pcm` into pieces no longer than `pieceMs`. */
export function planPieces(pcm: Int16Array, pieceMs = 30_000): number[] {
  const piece = samplesFor(pieceMs);
  const search = samplesFor(Math.min(5000, pieceMs / 3));
  const cuts: number[] = [];
  let start = 0;
  while (pcm.length - start > piece) {
    const cut = quietestPoint(pcm, start + piece - search, start + piece);
    cuts.push(cut);
    start = cut;
  }
  return cuts;
}

export async function transcribePcm(
  pcm: Int16Array,
  adapter: SttAdapter,
  options: FileTranscribeOptions = {},
): Promise<FileTranscript> {
  const cap = samplesFor(options.maxDurationMs ?? 30 * 60_000);
  const truncated = pcm.length > cap;
  const audio = truncated ? pcm.subarray(0, cap) : pcm;
  const bounds = [0, ...planPieces(audio, options.pieceMs), audio.length];
  const segments: FileTranscript['segments'] = [];
  let language = '';
  for (let i = 0; i + 1 < bounds.length; i++) {
    if (options.isCancelled?.()) {
      throw new FileTranscribeError(voiceError('cancelled'));
    }
    const piece = audio.subarray(bounds[i]!, bounds[i + 1]!);
    // Pieces of pure silence are skipped: recognisers invent text for them.
    if (rms(piece) > 0.001) {
      const result = await adapter.transcribe(piece, {
        // Detect on the first piece, then stay in that language.
        language: language || options.language || 'auto',
        punctuate: true,
        context: joinSegments(segments.map(s => s.text)),
      });
      language ||= result.language;
      if (result.text && !isPhantom(result.text, durationMs(piece.length))) {
        segments.push({
          startMs: durationMs(bounds[i]!),
          endMs: durationMs(bounds[i + 1]!),
          text: result.text,
        });
      }
    }
    options.onProgress?.(
      bounds[i + 1]! / audio.length,
      joinSegments(segments.map(s => s.text)),
    );
  }
  return {
    text: joinSegments(segments.map(s => s.text)),
    language,
    durationMs: durationMs(pcm.length),
    truncated,
    segments,
  };
}

export async function transcribeAudioFile(
  uri: string,
  decoder: AudioFileDecoder,
  adapter: SttAdapter,
  options: FileTranscribeOptions = {},
): Promise<FileTranscript> {
  let pcm: Int16Array;
  try {
    pcm = toSpeechPcm(await decoder.decode(uri));
  } catch (err) {
    throw new FileTranscribeError(voiceError('unsupported', err, false));
  }
  return transcribePcm(pcm, adapter, options);
}
