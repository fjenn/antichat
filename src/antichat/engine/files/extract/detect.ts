/**
 * What kind of document a file is: by magic bytes first (a renamed file is
 * still what it is), then MIME type, then extension.
 */
import type {DocumentKind} from './types';

const CODE = new Set(
  (
    'ts tsx js jsx mjs cjs py rb php java kt kts swift c h cc cpp hpp cs go rs ' +
    'sh bash zsh ps1 sql yaml yml toml ini cfg conf xml css scss less vue svelte ' +
    'dart lua pl r m mm scala gradle properties env dockerfile makefile tex'
  ).split(' '),
);
const IMAGE = new Set(
  'png jpg jpeg heic heif webp gif bmp tif tiff'.split(' '),
);
const AUDIO = new Set(
  'mp3 m4a wav aac ogg oga opus flac caf amr aiff'.split(' '),
);

const startsWith = (head: Uint8Array | undefined, bytes: number[]) =>
  !!head && head.length >= bytes.length && bytes.every((b, i) => head[i] === b);

export function extensionOf(name: string): string {
  const base = name.split(/[\\/]/).pop() ?? '';
  const dot = base.lastIndexOf('.');
  return dot < 0 ? base.toLowerCase() : base.slice(dot + 1).toLowerCase();
}

export function detectKind(input: {
  name: string;
  mimeType?: string | null;
  head?: Uint8Array;
}): DocumentKind {
  const ext = extensionOf(input.name);
  const mime = (input.mimeType ?? '').toLowerCase();
  const {head} = input;
  if (startsWith(head, [0x25, 0x50, 0x44, 0x46])) {
    return 'pdf';
  }
  if (startsWith(head, [0x50, 0x4b, 0x03, 0x04])) {
    if (ext === 'pptx' || mime.includes('presentationml')) {
      return 'pptx';
    }
    if (ext === 'xlsx' || mime.includes('spreadsheetml')) {
      return 'xlsx';
    }
    if (ext === 'docx' || mime.includes('wordprocessingml')) {
      return 'docx';
    }
    return 'unknown';
  }
  if (
    startsWith(head, [0x89, 0x50, 0x4e, 0x47]) ||
    startsWith(head, [0xff, 0xd8, 0xff])
  ) {
    return 'image';
  }
  if (startsWith(head, [0x7b, 0x5c, 0x72, 0x74, 0x66])) {
    return 'rtf';
  }
  if (ext === 'pdf' || mime === 'application/pdf') {
    return 'pdf';
  }
  if (ext === 'docx' || ext === 'pptx' || ext === 'xlsx') {
    return ext;
  }
  if (IMAGE.has(ext) || mime.startsWith('image/')) {
    return 'image';
  }
  if (AUDIO.has(ext) || mime.startsWith('audio/')) {
    return 'audio';
  }
  if (ext === 'csv' || ext === 'tsv' || mime === 'text/csv') {
    return 'csv';
  }
  if (ext === 'md' || ext === 'markdown') {
    return 'markdown';
  }
  if (ext === 'json' || ext === 'jsonl' || mime === 'application/json') {
    return 'json';
  }
  if (ext === 'html' || ext === 'htm' || mime === 'text/html') {
    return 'html';
  }
  if (ext === 'rtf') {
    return 'rtf';
  }
  if (CODE.has(ext)) {
    return 'code';
  }
  if (ext === 'txt' || ext === 'log' || mime.startsWith('text/')) {
    return 'text';
  }
  return 'unknown';
}
