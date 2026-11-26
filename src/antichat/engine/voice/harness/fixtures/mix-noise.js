/* eslint-env node */
/* eslint-disable no-bitwise */
// Adds seeded pink-ish noise to a 16 kHz mono 16-bit WAV at a given SNR, or
// writes noise only.  node mix-noise.js <id> <snrDb> <seed>
//                     node mix-noise.js --noise-only <id> <seconds> <seed>
const fs = require('fs');
const path = require('path');

const HEADER = 44;
function rng(seed) {
  let s = seed >>> 0 || 1;
  return () => {
    s ^= s << 13;
    s >>>= 0;
    s ^= s >> 17;
    s ^= s << 5;
    s >>>= 0;
    return s / 0xffffffff - 0.5;
  };
}
function pink(n, seed) {
  const r = rng(seed);
  const out = new Float32Array(n);
  let b0 = 0,
    b1 = 0,
    b2 = 0;
  for (let i = 0; i < n; i++) {
    const w = r();
    b0 = 0.99765 * b0 + w * 0.099046;
    b1 = 0.963 * b1 + w * 0.2965164;
    b2 = 0.57 * b2 + w * 1.0526913;
    out[i] = b0 + b1 + b2 + w * 0.1848;
  }
  return out;
}
const rms = a => Math.sqrt(a.reduce((s, v) => s + v * v, 0) / a.length);
function wav(samples) {
  const buf = Buffer.alloc(HEADER + samples.length * 2);
  buf.write('RIFF', 0);
  buf.writeUInt32LE(36 + samples.length * 2, 4);
  buf.write('WAVEfmt ', 8);
  buf.writeUInt32LE(16, 16);
  buf.writeUInt16LE(1, 20);
  buf.writeUInt16LE(1, 22);
  buf.writeUInt32LE(16000, 24);
  buf.writeUInt32LE(32000, 28);
  buf.writeUInt16LE(2, 32);
  buf.writeUInt16LE(16, 34);
  buf.write('data', 36);
  buf.writeUInt32LE(samples.length * 2, 40);
  for (let i = 0; i < samples.length; i++) {
    buf.writeInt16LE(
      Math.max(-32768, Math.min(32767, Math.round(samples[i] * 32767))),
      HEADER + i * 2,
    );
  }
  return buf;
}
function readWav(file) {
  const buf = fs.readFileSync(file);
  let at = 12;
  while (buf.toString('ascii', at, at + 4) !== 'data')
    at += 8 + buf.readUInt32LE(at + 4);
  const n = buf.readUInt32LE(at + 4) / 2;
  const out = new Float32Array(n);
  for (let i = 0; i < n; i++) out[i] = buf.readInt16LE(at + 8 + i * 2) / 32768;
  return out;
}

const args = process.argv.slice(2);
if (args[0] === '--noise-only') {
  const [, id, seconds, seed] = args;
  const noise = pink(16000 * Number(seconds), Number(seed));
  const gain = 0.004 / rms(noise); // about -48 dBFS: a quiet room
  fs.writeFileSync(
    path.join(__dirname, `${id}.wav`),
    wav(noise.map(v => v * gain)),
  );
} else {
  const [id, snr, seed] = args;
  const speech = readWav(path.join(__dirname, `${id}.wav`));
  const noise = pink(speech.length, Number(seed));
  const voiced = speech.filter(v => Math.abs(v) > 0.01);
  const gain = rms(voiced) / rms(noise) / Math.pow(10, Number(snr) / 20);
  fs.writeFileSync(
    path.join(__dirname, `${id}-snr${snr}.wav`),
    wav(speech.map((v, i) => v + noise[i] * gain)),
  );
}
