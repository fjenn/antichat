/* eslint-disable no-bitwise */
/** Base64 for byte arrays, without a Buffer polyfill. */
const ALPHABET =
  'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

const LOOKUP = (() => {
  const table = new Uint8Array(128).fill(255);
  for (let index = 0; index < ALPHABET.length; index++) {
    table[ALPHABET.charCodeAt(index)] = index;
  }
  return table;
})();

export function bytesToBase64(bytes: Uint8Array): string {
  const parts: string[] = [];
  let chunk = '';
  for (let index = 0; index < bytes.length; index += 3) {
    const a = bytes[index];
    const b = index + 1 < bytes.length ? bytes[index + 1] : 0;
    const c = index + 2 < bytes.length ? bytes[index + 2] : 0;
    chunk += ALPHABET[a >> 2];
    chunk += ALPHABET[((a & 3) << 4) | (b >> 4)];
    chunk +=
      index + 1 < bytes.length ? ALPHABET[((b & 15) << 2) | (c >> 6)] : '=';
    chunk += index + 2 < bytes.length ? ALPHABET[c & 63] : '=';
    if (chunk.length >= 8192) {
      parts.push(chunk);
      chunk = '';
    }
  }
  parts.push(chunk);
  return parts.join('');
}

export function base64ToBytes(base64: string): Uint8Array {
  const clean = base64.replace(/[^A-Za-z0-9+/]/g, '');
  const length = Math.floor((clean.length * 3) / 4);
  const bytes = new Uint8Array(length);
  let out = 0;
  for (let index = 0; index < clean.length; index += 4) {
    const a = LOOKUP[clean.charCodeAt(index)];
    const b = LOOKUP[clean.charCodeAt(index + 1)] ?? 0;
    const c = LOOKUP[clean.charCodeAt(index + 2)];
    const d = LOOKUP[clean.charCodeAt(index + 3)];
    bytes[out++] = (a << 2) | (b >> 4);
    if (c !== undefined && c !== 255 && out < length) {
      bytes[out++] = ((b & 15) << 4) | (c >> 2);
    }
    if (d !== undefined && d !== 255 && out < length) {
      bytes[out++] = ((c & 3) << 6) | d;
    }
  }
  return bytes;
}
