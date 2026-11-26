/** Shapes shared by every extractor. */
export type DocumentKind =
  | 'pdf'
  | 'docx'
  | 'pptx'
  | 'xlsx'
  | 'csv'
  | 'text'
  | 'markdown'
  | 'code'
  | 'json'
  | 'html'
  | 'rtf'
  | 'image'
  | 'audio'
  | 'unknown';

/** What a "page" is called when an answer cites it. */
export type PageLabel = 'page' | 'slide' | 'sheet' | 'section';

export interface ExtractedPage {
  /** 1-based. */
  page: number;
  text: string;
  /** Slide title or sheet name. */
  title?: string;
  /** The text came from OCR, not from a text layer. */
  ocr?: boolean;
}

export type Cell = string | number | null;

export interface ExtractedTable {
  name: string;
  columns: string[];
  rows: Cell[][];
  /** Rows dropped because of the cap. */
  truncatedRows: number;
}

export interface ExtractedDocument {
  kind: DocumentKind;
  pageLabel: PageLabel;
  pages: ExtractedPage[];
  tables: ExtractedTable[];
  warnings: string[];
}

export interface ExtractLimits {
  maxChars: number;
  maxTableRows: number;
  maxTableColumns: number;
}

export type ExtractErrorCode =
  | 'encrypted'
  | 'corrupt'
  | 'unsupported'
  | 'too_large'
  | 'empty';

export class ExtractError extends Error {
  constructor(
    readonly code: ExtractErrorCode,
    message: string,
  ) {
    super(message);
    this.name = 'ExtractError';
  }
}
