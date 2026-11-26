import {
  bytesToPcm,
  chunked,
  concatPcm,
  floatToPcm,
  meterLevel,
  mixPcm,
  mixToMono,
  pcmToBytes,
  quietestPoint,
  resample,
  rms,
  silence,
  toDb,
} from '../audio/pcm';
import {encodeWav, parseWav, wavToSpeechPcm} from '../audio/wav';
import {fixturePcm} from '../harness/fixtures';

const tone = (ms: number, amplitude = 0.3, rate = 16000) =>
  floatToPcm(
    Float32Array.from(
      {length: (rate * ms) / 1000},
      (_, i) => Math.sin((2 * Math.PI * 440 * i) / rate) * amplitude,
    ),
  );

describe('pcm', () => {
  it('round-trips samples through little-endian bytes', () => {
    const pcm = Int16Array.from([0, 1, -1, 32767, -32768, 1234, -4321]);
    expect(Array.from(bytesToPcm(pcmToBytes(pcm)))).toEqual(Array.from(pcm));
  });

  it('measures level', () => {
    expect(rms(silence(100))).toBe(0);
    expect(toDb(0)).toBe(-100);
    expect(toDb(rms(tone(100, 0.5)))).toBeCloseTo(-9.03, 0);
    expect(meterLevel(0)).toBe(0);
    expect(meterLevel(1)).toBe(1);
  });

  it('concatenates, chunks and mixes', () => {
    const a = tone(100);
    const b = tone(40);
    expect(concatPcm([a, b]).length).toBe(a.length + b.length);
    const chunks = [...chunked(concatPcm([a, b]), 50)];
    expect(chunks.map(c => c.length)).toEqual([800, 800, 640]);
    const mixed = mixPcm(silence(100), b, 0.5, 160);
    expect(mixed.length).toBe(1600);
    expect(rms(mixed, 0, 160)).toBe(0);
    expect(rms(mixed, 160, 800)).toBeGreaterThan(0.05);
  });

  it('resamples and mixes channels down', () => {
    const stereo = [
      new Float32Array([1, 1, 1, 1]),
      new Float32Array([0, 0, 0, 0]),
    ];
    expect(Array.from(mixToMono(stereo))).toEqual([0.5, 0.5, 0.5, 0.5]);
    const down = resample(new Float32Array(48000).fill(0.25), 48000, 16000);
    expect(down.length).toBe(16000);
    expect(down[100]).toBeCloseTo(0.25);
    expect(resample(new Float32Array(8000).fill(0.5), 8000, 16000).length).toBe(
      16000,
    );
  });

  it('finds the quietest point for a cut', () => {
    const pcm = concatPcm([tone(1000), silence(300), tone(1000)]);
    const cut = quietestPoint(pcm, 0, pcm.length);
    expect(cut).toBeGreaterThan(16000);
    expect(cut).toBeLessThan(16000 + 4800);
  });
});

describe('wav', () => {
  it('round-trips 16 kHz mono', () => {
    const pcm = tone(250);
    const parsed = parseWav(encodeWav(pcm));
    expect(parsed.sampleRate).toBe(16000);
    expect(parsed.channels).toBe(1);
    expect(Array.from(wavToSpeechPcm(encodeWav(pcm)).slice(0, 50))).toEqual(
      Array.from(pcm.slice(0, 50)),
    );
  });

  it('converts 44.1 kHz stereo to speech PCM', () => {
    const stereo = new Int16Array(44100 * 2).fill(8000);
    const wav = encodeWav(stereo, 44100);
    new DataView(wav.buffer).setUint16(22, 2, true);
    new DataView(wav.buffer).setUint16(32, 4, true);
    const pcm = wavToSpeechPcm(wav);
    expect(pcm.length).toBe(16000);
    expect(pcm[500]).toBeGreaterThan(7900);
  });

  it('reads the fixtures, which carry extra chunks', () => {
    const pcm = fixturePcm('en-us-capital');
    expect(pcm.length).toBeGreaterThan(16000 * 2);
    expect(rms(pcm)).toBeGreaterThan(0.01);
  });

  it('rejects other data', () => {
    expect(() => parseWav(new Uint8Array(100))).toThrow('not a WAV');
  });
});
