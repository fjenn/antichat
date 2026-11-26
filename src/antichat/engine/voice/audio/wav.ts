/* eslint-disable no-bitwise */
/** WAV (RIFF PCM) reading and writing, for fixtures and audio attachments. */
import {SAMPLE_RATE} from '../types';
import {floatToPcm, mixToMono, resample} from './pcm';

export interface WavAudio {
  sampleRate: number;
  channels: number;
  /** Planar float samples, one array per channel. */
  data: Float32Array[];
}

const tag = (bytes: Uint8Array, at: number): string =>
  String.fromCharCode(
    bytes[at]!,
    bytes[at + 1]!,
    bytes[at + 2]!,
    bytes[at + 3]!,
  );

export function parseWav(bytes: Uint8Array): WavAudio {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (
    bytes.length < 44 ||
    tag(bytes, 0) !== 'RIFF' ||
    tag(bytes, 8) !== 'WAVE'
  ) {
    throw new Error('not a WAV file');
  }
  let format = 1;
  let channels = 1;
  let sampleRate = SAMPLE_RATE;
  let bits = 16;
  let at = 12;
  while (at + 8 <= bytes.length) {
    const id = tag(bytes, at);
    const size = view.getUint32(at + 4, true);
    const body = at + 8;
    if (id === 'fmt ') {
      format = view.getUint16(body, true);
      channels = view.getUint16(body + 2, true);
      sampleRate = view.getUint32(body + 4, true);
      bits = view.getUint16(body + 14, true);
    } else if (id === 'data') {
      const bytesPerSample = bits >> 3;
      const frames = Math.floor(
        Math.min(size, bytes.length - body) / (bytesPerSample * channels),
      );
      const data = Array.from(
        {length: channels},
        () => new Float32Array(frames),
      );
      for (let i = 0; i < frames; i++) {
        for (let c = 0; c < channels; c++) {
          const p = body + (i * channels + c) * bytesPerSample;
          let v: number;
          if (format === 3) {
            v =
              bits === 64 ? view.getFloat64(p, true) : view.getFloat32(p, true);
          } else if (bits === 16) {
            v = view.getInt16(p, true) / 32768;
          } else if (bits === 8) {
            v = (view.getUint8(p) - 128) / 128;
          } else if (bits === 24) {
            v =
              ((view.getInt8(p + 2) << 16) |
                (view.getUint8(p + 1) << 8) |
                view.getUint8(p)) /
              8388608;
          } else {
            v = view.getInt32(p, true) / 2147483648;
          }
          data[c]![i] = v;
        }
      }
      return {sampleRate, channels, data};
    }
    at = body + size + (size & 1);
  }
  throw new Error('WAV file has no data chunk');
}

/** Any decoded audio → the engine's 16 kHz mono Int16. */
export function toSpeechPcm(audio: WavAudio): Int16Array {
  return floatToPcm(
    resample(mixToMono(audio.data), audio.sampleRate, SAMPLE_RATE),
  );
}

export const wavToSpeechPcm = (bytes: Uint8Array): Int16Array =>
  toSpeechPcm(parseWav(bytes));

export function encodeWav(
  pcm: Int16Array,
  sampleRate = SAMPLE_RATE,
): Uint8Array {
  const out = new Uint8Array(44 + pcm.length * 2);
  const view = new DataView(out.buffer);
  const put = (at: number, text: string) => {
    for (let i = 0; i < text.length; i++) {
      out[at + i] = text.charCodeAt(i);
    }
  };
  put(0, 'RIFF');
  view.setUint32(4, 36 + pcm.length * 2, true);
  put(8, 'WAVEfmt ');
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * 2, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  put(36, 'data');
  view.setUint32(40, pcm.length * 2, true);
  for (let i = 0; i < pcm.length; i++) {
    view.setInt16(44 + i * 2, pcm[i]!, true);
  }
  return out;
}
