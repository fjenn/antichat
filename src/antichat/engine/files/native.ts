/**
 * The phone side of the files engine: reading bytes, PDF pages and OCR.
 * Everything above talks to the `FileIo` interface, so Jest runs the
 * pipeline with Node's file system and scripted pages.
 *
 * Native modules: `AntiChatPdf` (PDFKit / PDFium) and `AntiChatOcr`
 * (Apple Vision / ML Kit), in `ios/AntiChat/` and
 * `android/.../antichat/`.
 */
import {NativeModules} from 'react-native';

export interface OcrResult {
  text: string;
  lines: number;
  confidence: number;
}

export interface FileIo {
  /** Size in bytes, or null when unknown. */
  size(uri: string): Promise<number | null>;
  readBytes(uri: string, maxBytes?: number): Promise<Uint8Array>;
  /** Text of `count` PDF pages from `start` (0-based) and the page count. */
  pdfPages(
    uri: string,
    start: number,
    count: number,
  ): Promise<{pageCount: number; pages: string[]}>;
  ocrImage(uri: string): Promise<OcrResult>;
  ocrPdfPage(uri: string, index: number): Promise<OcrResult>;
  /** Copies a picked file into the app's own storage; returns the new URI. */
  keep?(uri: string, name: string): Promise<string>;
  remove?(uri: string): Promise<void>;
  writeText?(name: string, text: string): Promise<string>;
}

const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
let lookup: Uint8Array | null = null;

export function base64ToBytes(base64: string): Uint8Array {
  if (!lookup) {
    lookup = new Uint8Array(128);
    for (let i = 0; i < B64.length; i++) {
      lookup[B64.charCodeAt(i)] = i;
    }
  }
  const clean = base64.replace(/[^A-Za-z0-9+/]/g, '');
  const out = new Uint8Array(Math.floor((clean.length * 3) / 4));
  let o = 0;
  for (let i = 0; i + 1 < clean.length; i += 4) {
    const a = lookup[clean.charCodeAt(i)];
    const b = lookup[clean.charCodeAt(i + 1)];
    const c = i + 2 < clean.length ? lookup[clean.charCodeAt(i + 2)] : 0;
    const d = i + 3 < clean.length ? lookup[clean.charCodeAt(i + 3)] : 0;
    out[o++] = (a << 2) | (b >> 4);
    if (i + 2 < clean.length) {
      out[o++] = ((b & 15) << 4) | (c >> 2);
    }
    if (i + 3 < clean.length) {
      out[o++] = ((c & 3) << 6) | d;
    }
  }
  return out.subarray(0, o);
}

const path = (uri: string) =>
  uri.startsWith('file://') ? decodeURIComponent(uri.slice(7)) : uri;

/** The real thing. Loaded lazily so Jest never touches native modules. */
export function createNativeFileIo(): FileIo {
  const RNFS = require('@dr.pogodin/react-native-fs');
  const dir = `${RNFS.DocumentDirectoryPath}/antichat-files`;
  const pdf = NativeModules.AntiChatPdf;
  const ocr = NativeModules.AntiChatOcr;
  const need = <T>(module: T | undefined, name: string): T => {
    if (!module) {
      throw new Error(`${name} is not in this build`);
    }
    return module;
  };
  return {
    async size(uri) {
      try {
        return Number((await RNFS.stat(path(uri))).size);
      } catch {
        return null;
      }
    },
    async readBytes(uri, maxBytes) {
      const base64 = maxBytes
        ? await RNFS.read(path(uri), maxBytes, 0, 'base64')
        : await RNFS.readFile(path(uri), 'base64');
      return base64ToBytes(base64);
    },
    pdfPages: (uri, start, count) =>
      need(pdf, 'AntiChatPdf').pages(path(uri), start, count),
    ocrImage: uri => need(ocr, 'AntiChatOcr').image(path(uri)),
    ocrPdfPage: (uri, index) =>
      need(ocr, 'AntiChatOcr').pdfPage(path(uri), index),
    async keep(uri, name) {
      await RNFS.mkdir(dir);
      const safe = name.replace(/[^\w.\- ]+/g, '_').slice(-80) || 'file';
      const target = `${dir}/${Date.now().toString(36)}-${safe}`;
      await RNFS.copyFile(path(uri), target);
      return `file://${target}`;
    },
    async remove(uri) {
      if (path(uri).startsWith(dir)) {
        await RNFS.unlink(path(uri)).catch(() => undefined);
      }
    },
    async writeText(name, text) {
      await RNFS.mkdir(dir);
      const target = `${dir}/${Date.now().toString(36)}-${name}`;
      await RNFS.writeFile(target, text, 'utf8');
      return `file://${target}`;
    },
  };
}
