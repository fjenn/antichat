import nacl from 'tweetnacl';

import {decodeBase64, ed25519Verifier, utf8Bytes} from '../catalog/signature';
import {CATALOG_PUBLIC_KEYS} from '../catalog/remote';

const b64 = (bytes: Uint8Array) => Buffer.from(bytes).toString('base64');

describe('catalogue signature', () => {
  const pair = nacl.sign.keyPair();
  const other = nacl.sign.keyPair();
  const payload = '{"serial":2026112402,"note":"ünïcödé 模型 😀"}\n';
  const signature = b64(nacl.sign.detached(utf8Bytes(payload), pair.secretKey));

  it('encodes UTF-8 like the platform does', () => {
    expect(Array.from(utf8Bytes(payload))).toEqual(
      Array.from(Buffer.from(payload, 'utf8')),
    );
  });

  it('decodes base64 and rejects malformed text', () => {
    expect(Array.from(decodeBase64('AQID') as Uint8Array)).toEqual([1, 2, 3]);
    expect(Array.from(decodeBase64('AQI=') as Uint8Array)).toEqual([1, 2]);
    expect(Array.from(decodeBase64(' AQ==\n') as Uint8Array)).toEqual([1]);
    expect(decodeBase64('A')).toBeNull();
    expect(decodeBase64('AQ!D')).toBeNull();
  });

  it('accepts a signature from a pinned key', async () => {
    const verifier = ed25519Verifier([b64(pair.publicKey)]);
    expect(await verifier.verify(payload, signature)).toBe(true);
  });

  it('accepts any one of several pinned keys', async () => {
    const verifier = ed25519Verifier([
      b64(other.publicKey),
      b64(pair.publicKey),
    ]);
    expect(await verifier.verify(payload, signature)).toBe(true);
  });

  it('rejects a changed payload, a foreign key and a broken signature', async () => {
    const verifier = ed25519Verifier([b64(pair.publicKey)]);
    expect(await verifier.verify(payload + ' ', signature)).toBe(false);
    expect(
      await ed25519Verifier([b64(other.publicKey)]).verify(payload, signature),
    ).toBe(false);
    expect(await verifier.verify(payload, signature.slice(4))).toBe(false);
    expect(await verifier.verify(payload, 'not base64 !')).toBe(false);
    expect(await verifier.verify(payload, '')).toBe(false);
  });

  it('verifies nothing without a usable key', async () => {
    expect(await ed25519Verifier([]).verify(payload, signature)).toBe(false);
    expect(await ed25519Verifier(['AQID']).verify(payload, signature)).toBe(
      false,
    );
  });

  it('ships a well-formed placeholder key that did not sign this', async () => {
    expect(CATALOG_PUBLIC_KEYS).toHaveLength(1);
    expect(decodeBase64(CATALOG_PUBLIC_KEYS[0])).toHaveLength(32);
    expect(
      await ed25519Verifier(CATALOG_PUBLIC_KEYS).verify(payload, signature),
    ).toBe(false);
  });
});
