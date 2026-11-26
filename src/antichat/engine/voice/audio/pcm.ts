/* eslint-disable no-bitwise */
/** PCM helpers. All speech audio is 16 kHz mono Int16 (see types.ts). */
import {SAMPLES_PER_MS} from '../types';

export const durationMs = (samples: number): number => samples / SAMPLES_PER_MS;
export const samplesFor = (ms: number): number =>
  Math.round(ms * SAMPLES_PER_MS);

export function concatPcm(chunks: readonly Int16Array[]): Int16Array {
  let total = 0;
  for (const chunk of chunks) {
    total += chunk.length;
  }
  const out = new Int16Array(total);
  let at = 0;
  for (const chunk of chunks) {
    out.set(chunk, at);
    at += chunk.length;
  }
  return out;
}

/** Root mean square of a frame, 0..1. */
export function rms(pcm: Int16Array, from = 0, to = pcm.length): number {
  const n = to - from;
  if (n <= 0) {
    return 0;
  }
  let sum = 0;
  for (let i = from; i < to; i++) {
    const v = pcm[i]! / 32768;
    sum += v * v;
  }
  return Math.sqrt(sum / n);
}

/** Level in dBFS; digital silence is -100. */
export const toDb = (linear: number): number =>
  linear <= 1e-5 ? -100 : 20 * Math.log10(linear);

/** 0..1 meter value for a waveform: -60 dBFS → 0, -10 dBFS → 1. */
export const meterLevel = (linear: number): number =>
  Math.min(1, Math.max(0, (toDb(linear) + 60) / 50));

/** Little-endian bytes ↔ samples (the mic and whisper.rn speak bytes). */
export function bytesToPcm(bytes: Uint8Array): Int16Array {
  const out = new Int16Array(bytes.length >> 1);
  for (let i = 0; i < out.length; i++) {
    const v = bytes[i * 2]! | (bytes[i * 2 + 1]! << 8);
    out[i] = v >= 0x8000 ? v - 0x10000 : v;
  }
  return out;
}

export function pcmToBytes(pcm: Int16Array): Uint8Array {
  const out = new Uint8Array(pcm.length * 2);
  for (let i = 0; i < pcm.length; i++) {
    const v = pcm[i]!;
    out[i * 2] = v & 0xff;
    out[i * 2 + 1] = (v >> 8) & 0xff;
  }
  return out;
}

export function floatToPcm(
  samples: Float32Array | readonly number[],
): Int16Array {
  const out = new Int16Array(samples.length);
  for (let i = 0; i < samples.length; i++) {
    const v = Math.max(-1, Math.min(1, samples[i]!));
    out[i] = Math.round(v * 32767);
  }
  return out;
}

/** Averages interleaved or planar channels to mono floats. */
export function mixToMono(channels: readonly Float32Array[]): Float32Array {
  if (channels.length === 1) {
    return channels[0]!;
  }
  const n = channels[0]?.length ?? 0;
  const out = new Float32Array(n);
  for (const channel of channels) {
    for (let i = 0; i < n; i++) {
      out[i]! += channel[i]! / channels.length;
    }
  }
  return out;
}

/**
 * Resamples mono floats to `toRate`. Downsampling averages each output
 * sample's source window (a box filter, enough to keep speech clean for
 * recognition); upsampling interpolates linearly.
 */
export function resample(
  input: Float32Array,
  fromRate: number,
  toRate: number,
): Float32Array {
  if (fromRate === toRate || input.length === 0) {
    return input;
  }
  const ratio = fromRate / toRate;
  const n = Math.floor(input.length / ratio);
  const out = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    const start = i * ratio;
    if (ratio > 1) {
      const end = Math.min(input.length, Math.floor(start + ratio));
      let sum = 0;
      let count = 0;
      for (let j = Math.floor(start); j < end; j++) {
        sum += input[j]!;
        count++;
      }
      out[i] = count ? sum / count : 0;
    } else {
      const left = Math.floor(start);
      const right = Math.min(input.length - 1, left + 1);
      const t = start - left;
      out[i] = input[left]! * (1 - t) + input[right]! * t;
    }
  }
  return out;
}

/** `a + b * gain`, as long as the longer input; clips to 16 bits. */
export function mixPcm(
  a: Int16Array,
  b: Int16Array,
  gain = 1,
  offset = 0,
): Int16Array {
  const out = new Int16Array(Math.max(a.length, offset + b.length));
  out.set(a);
  for (let i = 0; i < b.length; i++) {
    const v = out[offset + i]! + b[i]! * gain;
    out[offset + i] = Math.max(-32768, Math.min(32767, Math.round(v)));
  }
  return out;
}

export const silence = (ms: number): Int16Array =>
  new Int16Array(samplesFor(ms));

/** Cuts `pcm` into chunks of `chunkMs`, as a microphone would deliver them. */
export function* chunked(pcm: Int16Array, chunkMs = 50): Generator<Int16Array> {
  const size = samplesFor(chunkMs);
  for (let at = 0; at < pcm.length; at += size) {
    yield pcm.subarray(at, Math.min(pcm.length, at + size));
  }
}

/**
 * Index of the quietest `windowMs` window in `[from, to)`: where a long
 * recording is cut so that no word is split.
 */
export function quietestPoint(
  pcm: Int16Array,
  from: number,
  to: number,
  windowMs = 100,
): number {
  const window = samplesFor(windowMs);
  let best = Math.max(from, to - window);
  let bestLevel = Infinity;
  for (let at = from; at + window <= to; at += window >> 1) {
    const level = rms(pcm, at, at + window);
    if (level < bestLevel) {
      bestLevel = level;
      best = at + (window >> 1);
    }
  }
  return best;
}
