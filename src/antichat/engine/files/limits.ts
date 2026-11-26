/**
 * Budgets of the files engine per device class, and the limits a user can
 * run into, as data. The UI words them (`locales`); nothing here is a
 * sentence shown to the user.
 */
import type {DeviceClass} from '../prompt/types';

export interface FileBudget {
  maxFilesPerMessage: number;
  /** Files kept per chat (ChatGPT: 20). */
  maxFilesPerChat: number;
  maxFileBytes: number;
  /** Pages (slides, sheets) read from one file. */
  maxPages: number;
  /** Characters read from one file at most. */
  maxChars: number;
  /** Tokens of file text that may be put into the prompt whole, all files. */
  inlineTokens: number;
  /** Excerpts added per question for files that are searched. */
  retrievedChunks: number;
  chunkTokens: number;
  /** Pages without a text layer that are read with OCR. */
  ocrPages: number;
  maxTableRows: number;
  maxTableColumns: number;
  /** Rows of a query result shown to the model. */
  sqlResultRows: number;
  /** Pasted text longer than this becomes an attachment. */
  pasteThresholdChars: number;
  /** Images sent to a vision model per message. */
  maxImages: number;
  /** Audio that may be transcribed, in minutes (0 = not on this class). */
  audioMinutes: number;
  /** Embed chunks for semantic search (else keywords only). */
  embeddings: boolean;
}

const MB = 1024 * 1024;

const BY_CLASS: Record<
  DeviceClass,
  Omit<FileBudget, 'inlineTokens'> & {inlineShare: number}
> = {
  // 4 GB: one file, searched not stuffed, keywords only.
  A: {
    maxFilesPerMessage: 1,
    maxFilesPerChat: 5,
    maxFileBytes: 20 * MB,
    maxPages: 150,
    maxChars: 600_000,
    inlineShare: 0.15,
    retrievedChunks: 3,
    chunkTokens: 250,
    ocrPages: 5,
    maxTableRows: 20_000,
    maxTableColumns: 40,
    sqlResultRows: 20,
    pasteThresholdChars: 2000,
    maxImages: 1,
    audioMinutes: 0,
    embeddings: false,
  },
  B: {
    maxFilesPerMessage: 3,
    maxFilesPerChat: 10,
    maxFileBytes: 30 * MB,
    maxPages: 300,
    maxChars: 1_500_000,
    inlineShare: 0.3,
    retrievedChunks: 4,
    chunkTokens: 350,
    ocrPages: 10,
    maxTableRows: 50_000,
    maxTableColumns: 60,
    sqlResultRows: 30,
    pasteThresholdChars: 4000,
    maxImages: 1,
    audioMinutes: 10,
    embeddings: true,
  },
  C: {
    maxFilesPerMessage: 5,
    maxFilesPerChat: 20,
    maxFileBytes: 50 * MB,
    maxPages: 600,
    maxChars: 3_000_000,
    inlineShare: 0.4,
    retrievedChunks: 5,
    chunkTokens: 400,
    ocrPages: 20,
    maxTableRows: 100_000,
    maxTableColumns: 80,
    sqlResultRows: 40,
    pasteThresholdChars: 6000,
    maxImages: 3,
    audioMinutes: 30,
    embeddings: true,
  },
  D: {
    maxFilesPerMessage: 10,
    maxFilesPerChat: 20,
    maxFileBytes: 100 * MB,
    maxPages: 1000,
    maxChars: 6_000_000,
    inlineShare: 0.5,
    retrievedChunks: 6,
    chunkTokens: 450,
    ocrPages: 40,
    maxTableRows: 200_000,
    maxTableColumns: 100,
    sqlResultRows: 50,
    pasteThresholdChars: 10_000,
    maxImages: 5,
    audioMinutes: 30,
    embeddings: true,
  },
};

export function fileBudgetFor(
  deviceClass: DeviceClass | undefined,
  nCtx: number,
): FileBudget {
  const {inlineShare, ...rest} = BY_CLASS[deviceClass ?? 'B'];
  return {
    ...rest,
    // Never more than 20k tokens, whatever the window (gap analysis H11).
    inlineTokens: Math.min(20_000, Math.floor(nCtx * inlineShare)),
  };
}

/** What the user may be told. `params` fill the sentence the UI words. */
export type FileLimitCode =
  | 'too_many_files'
  | 'chat_file_limit'
  | 'file_too_large'
  | 'pages_capped'
  | 'text_truncated'
  | 'table_truncated'
  | 'ocr_pages_capped'
  | 'ocr_used'
  | 'no_text_found'
  | 'vision_unavailable'
  | 'images_capped'
  | 'audio_unavailable'
  | 'audio_too_long'
  | 'unsupported_type'
  | 'encrypted'
  | 'keyword_search_only'
  | 'searched_not_read_whole';

export interface FileLimit {
  code: FileLimitCode;
  /** Blocks the file (it cannot be used) or just informs. */
  severity: 'blocked' | 'info';
  params?: Record<string, number | string>;
}

export const limit = (
  code: FileLimitCode,
  severity: FileLimit['severity'],
  params?: FileLimit['params'],
): FileLimit => ({code, severity, ...(params ? {params} : {})});
