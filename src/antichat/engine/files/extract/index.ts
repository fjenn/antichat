/** Extraction of everything that needs no native code. */
import {extractCsv} from './csv';
import {detectKind} from './detect';
import {extractDocx, extractPptx, extractXlsx} from './office';
import {decodeText, extractText} from './text';
import type {ExtractedDocument, ExtractLimits} from './types';

export * from './types';
export * from './detect';
export * from './text';
export * from './csv';
export * from './office';
export * from './normalize';

/**
 * Dispatches by kind. PDF, images and audio are read natively: they come
 * back with their kind and no pages, and the caller routes them.
 */
export function extractFromBytes(
  bytes: Uint8Array,
  file: {name: string; mimeType?: string | null},
  limits: ExtractLimits,
): ExtractedDocument {
  const kind = detectKind({...file, head: bytes.subarray(0, 16)});
  switch (kind) {
    case 'docx':
      return extractDocx(bytes, limits);
    case 'pptx':
      return extractPptx(bytes, limits);
    case 'xlsx':
      return extractXlsx(bytes, limits);
    case 'csv':
      return extractCsv(
        decodeText(bytes),
        limits,
        file.name.replace(/\.[^.]+$/, ''),
      );
    case 'pdf':
    case 'image':
    case 'audio':
      return {kind, pageLabel: 'page', pages: [], tables: [], warnings: []};
    case 'unknown':
      // Unknown extension: text if it decodes as text without NUL bytes.
      if (bytes.subarray(0, 4096).includes(0)) {
        return {
          kind,
          pageLabel: 'page',
          pages: [],
          tables: [],
          warnings: ['unsupported'],
        };
      }
      return extractText(bytes, 'text', limits);
    default:
      return extractText(bytes, kind, limits);
  }
}
