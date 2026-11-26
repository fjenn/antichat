import nacl from 'tweetnacl';

import type {CatalogSignatureVerifier} from './store';

/**
 * Ed25519 check of the catalogue's detached signature, with tweetnacl
 * (audited by Cure53; pure JavaScript, so it runs in Hermes and in Jest).
 *
 * The signature covers the exact bytes of the catalogue as served (UTF-8).
 * Several keys may be pinned so a key can be rotated without an app release:
 * a signature from any one of them is accepted.
 */

const ALPHABET =
  'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

/** Strict base64 (standard alphabet, padded or not); null when malformed. */
export function decodeBase64(text: string): Uint8Array | null {
  const clean = text.replace(/\s+/g, '').replace(/[=]+$/, '');
  if (clean.length % 4 === 1) {
    return null;
  }
  const out = new Uint8Array(Math.floor((clean.length * 3) / 4));
  let buffer = 0;
  let bits = 0;
  let index = 0;
  for (const char of clean) {
    const value = ALPHABET.indexOf(char);
    if (value < 0) {
      return null;
    }
    buffer = buffer * 64 + value;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[index++] = Math.floor(buffer / 2 ** bits) % 256;
      buffer %= 2 ** bits;
    }
  }
  return out;
}

/** UTF-8 bytes of a string, without relying on a global TextEncoder. */
export function utf8Bytes(text: string): Uint8Array {
  const bytes: number[] = [];
  for (const char of text) {
    const code = char.codePointAt(0) as number;
    if (code < 0x80) {
      bytes.push(code);
    } else if (code < 0x800) {
      bytes.push(0xc0 + Math.floor(code / 64), 0x80 + (code % 64));
    } else if (code < 0x10000) {
      bytes.push(
        0xe0 + Math.floor(code / 4096),
        0x80 + (Math.floor(code / 64) % 64),
        0x80 + (code % 64),
      );
    } else {
      bytes.push(
        0xf0 + Math.floor(code / 262144),
        0x80 + (Math.floor(code / 4096) % 64),
        0x80 + (Math.floor(code / 64) % 64),
        0x80 + (code % 64),
      );
    }
  }
  return Uint8Array.from(bytes);
}

/**
 * @param publicKeysBase64 pinned Ed25519 public keys (32 bytes each, base64).
 *   Malformed keys are ignored; with no usable key nothing verifies.
 */
export function ed25519Verifier(
  publicKeysBase64: readonly string[],
): CatalogSignatureVerifier {
  const keys = publicKeysBase64
    .map(decodeBase64)
    .filter(
      (key): key is Uint8Array =>
        key !== null && key.length === nacl.sign.publicKeyLength,
    );
  return {
    async verify(payload: string, signature: string): Promise<boolean> {
      const sig = decodeBase64(signature);
      if (sig === null || sig.length !== nacl.sign.signatureLength) {
        return false;
      }
      const message = utf8Bytes(payload);
      return keys.some(key => nacl.sign.detached.verify(message, sig, key));
    },
  };
}
