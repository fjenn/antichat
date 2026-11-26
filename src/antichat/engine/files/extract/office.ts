/**
 * Word, PowerPoint and Excel files without a dependency beyond `fflate`:
 * they are zip archives of XML, and only the parts with text are inflated.
 *
 * The XML reading is a tolerant tag scanner, not a parser: these files are
 * machine-written, and a scanner survives the odd broken one.
 */
import {unzipSync} from 'fflate';

import {tableFromRows, tablePreview} from './csv';
import {decodeEntities, decodeText} from './text';
import {ExtractError} from './types';
import type {
  ExtractedDocument,
  ExtractedPage,
  ExtractedTable,
  ExtractLimits,
} from './types';

type Entries = Record<string, Uint8Array>;

function unzip(bytes: Uint8Array, wanted: (name: string) => boolean): Entries {
  try {
    return unzipSync(bytes, {filter: file => wanted(file.name)});
  } catch (error) {
    const message = String(error);
    throw new ExtractError(
      /encrypt/i.test(message) ? 'encrypted' : 'corrupt',
      `The file could not be opened: ${message}`,
    );
  }
}

const xml = (entries: Entries, name: string): string =>
  entries[name] ? decodeText(entries[name]) : '';

const attr = (tag: string, name: string): string | undefined => {
  const m = new RegExp(`(?:^|\\s)${name}="([^"]*)"`).exec(tag);
  return m ? decodeEntities(m[1]) : undefined;
};

interface Token {
  /** Tag name with prefix, e.g. "w:p"; empty for text. */
  name: string;
  open: boolean;
  close: boolean;
  raw: string;
  text?: string;
}

function* scan(source: string): Generator<Token> {
  const re = /<(\/?)([A-Za-z_][\w:.-]*)([^>]*?)(\/?)>|([^<]+)/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(source))) {
    if (m[5] !== undefined) {
      yield {name: '', open: false, close: false, raw: m[5], text: m[5]};
    } else {
      yield {
        name: m[2],
        open: m[1] === '',
        close: m[1] === '/' || m[4] === '/',
        raw: m[3],
      };
    }
  }
}

const cap = (pages: ExtractedPage[], limits: ExtractLimits): string[] => {
  let left = limits.maxChars;
  const warnings: string[] = [];
  for (const page of pages) {
    if (page.text.length > left) {
      page.text = page.text.slice(0, Math.max(0, left));
      if (!warnings.length) {
        warnings.push('truncated');
      }
    }
    left -= page.text.length;
  }
  return warnings;
};

// ------------------------------------------------------------------ docx

/** Body text of a WordprocessingML part, with "\f" at page breaks. */
function wordText(source: string): string {
  let out = '';
  let paragraph = '';
  let style = '';
  let inText = false;
  let cellDepth = 0;
  let row: string[] = [];
  let cell = '';
  let list = false;
  const endParagraph = () => {
    // A page break is kept as "\f" on its own; `trim` would eat it.
    const breaks = paragraph.includes('\f') && cellDepth === 0;
    let line = paragraph.replace(/\f/g, ' ').trim();
    paragraph = '';
    if (breaks) {
      out += '\f';
    }
    const heading = /^(heading|berschrift|titre|ttulo)?\s*([1-6])$/i.exec(
      style.replace(/[^\w ]/g, ''),
    );
    if (line && /^title$/i.test(style)) {
      line = `# ${line}`;
    } else if (line && heading) {
      line = `${'#'.repeat(Number(heading[2]))} ${line}`;
    } else if (line && (list || /^list(bullet|number)/i.test(style))) {
      line = `- ${line}`;
    }
    style = '';
    list = false;
    if (cellDepth > 0) {
      cell += (cell && line ? ' ' : '') + line;
    } else if (line) {
      out += line + '\n\n';
    }
  };
  for (const token of scan(source)) {
    if (token.name === '') {
      if (inText) {
        paragraph += decodeEntities(token.text!);
      }
      continue;
    }
    switch (token.name) {
      case 'w:t':
        inText = token.open && !token.close;
        break;
      case 'w:tab':
        paragraph += '\t';
        break;
      case 'w:br':
      case 'w:cr':
        paragraph += attr(token.raw, 'w:type') === 'page' ? '\f' : '\n';
        break;
      case 'w:lastRenderedPageBreak':
        paragraph += '\f';
        break;
      case 'w:pStyle':
        style = attr(token.raw, 'w:val') ?? '';
        break;
      case 'w:numPr':
        list = true;
        break;
      case 'w:p':
        if (!token.open || token.close) {
          endParagraph();
        }
        break;
      case 'w:tc':
        if (token.open && !token.close) {
          cellDepth++;
          cell = '';
        } else if (cellDepth > 0) {
          cellDepth--;
          row.push(cell.replace(/\s+/g, ' ').trim());
        }
        break;
      case 'w:tr':
        if (!token.open && row.length) {
          out += `| ${row.join(' | ')} |\n`;
          row = [];
        }
        break;
      case 'w:tbl':
        if (!token.open) {
          out += '\n';
        }
        break;
      default:
        break;
    }
  }
  endParagraph();
  return out;
}

export function extractDocx(
  bytes: Uint8Array,
  limits: ExtractLimits,
): ExtractedDocument {
  const entries = unzip(bytes, name =>
    /^word\/(document|footnotes|endnotes)\.xml$/.test(name),
  );
  const body = xml(entries, 'word/document.xml');
  if (!body) {
    throw new ExtractError('corrupt', 'Not a Word document');
  }
  let text = wordText(body);
  const notes = wordText(xml(entries, 'word/footnotes.xml')).replace(/\f/g, '');
  if (notes.trim()) {
    text += `\n\nFootnotes:\n${notes}`;
  }
  const clean = (part: string) => part.replace(/\n{3,}/g, '\n\n').trim();
  let parts = text.split('\f').map(clean).filter(Boolean);
  const paged = parts.length > 1;
  if (!paged) {
    // No page information: one section per top-level heading.
    parts = clean(text)
      .split(/\n(?=# )/)
      .map(clean)
      .filter(Boolean);
  }
  if (parts.length === 0) {
    throw new ExtractError('empty', 'The document has no text');
  }
  const pages = parts.map((part, index) => ({page: index + 1, text: part}));
  return {
    kind: 'docx',
    pageLabel: paged ? 'page' : 'section',
    pages,
    tables: [],
    warnings: cap(pages, limits),
  };
}

// ------------------------------------------------------------------ pptx

function relationships(source: string): Map<string, string> {
  const out = new Map<string, string>();
  for (const token of scan(source)) {
    if (token.name === 'Relationship') {
      const id = attr(token.raw, 'Id');
      const target = attr(token.raw, 'Target');
      if (id && target) {
        out.set(id, target);
      }
    }
  }
  return out;
}

const resolve = (base: string, target: string): string => {
  if (target.startsWith('/')) {
    return target.slice(1);
  }
  const parts = base.split('/').slice(0, -1);
  for (const piece of target.split('/')) {
    if (piece === '..') {
      parts.pop();
    } else if (piece !== '.') {
      parts.push(piece);
    }
  }
  return parts.join('/');
};

/** Paragraphs of a DrawingML part; the title placeholder comes back apart. */
function slideText(source: string): {title: string; lines: string[]} {
  const lines: string[] = [];
  let title = '';
  let paragraph = '';
  let inText = false;
  let isTitle = false;
  for (const token of scan(source)) {
    if (token.name === '') {
      if (inText) {
        paragraph += decodeEntities(token.text!);
      }
    } else if (token.name === 'a:t') {
      inText = token.open && !token.close;
    } else if (token.name === 'a:br') {
      paragraph += '\n';
    } else if (token.name === 'a:tab') {
      paragraph += '\t';
    } else if (token.name === 'p:sp' && token.open) {
      isTitle = false;
    } else if (token.name === 'p:ph') {
      const type = attr(token.raw, 'type');
      isTitle = type === 'title' || type === 'ctrTitle';
      // Slide numbers, dates and footers are furniture.
      if (type === 'sldNum' || type === 'dt' || type === 'ftr') {
        isTitle = false;
      }
    } else if (token.name === 'a:tc' && !token.open) {
      paragraph += ' | ';
    } else if (token.name === 'a:p' && (!token.open || token.close)) {
      const line = paragraph.trim();
      paragraph = '';
      if (!line) {
        continue;
      }
      if (isTitle && !title) {
        title = line;
      } else {
        lines.push(line);
      }
    }
  }
  return {title, lines};
}

export function extractPptx(
  bytes: Uint8Array,
  limits: ExtractLimits,
): ExtractedDocument {
  const entries = unzip(
    bytes,
    name =>
      name === 'ppt/presentation.xml' ||
      name === 'ppt/_rels/presentation.xml.rels' ||
      /^ppt\/slides\/(_rels\/)?slide\d+\.xml(\.rels)?$/.test(name) ||
      /^ppt\/notesSlides\/notesSlide\d+\.xml$/.test(name),
  );
  const rels = relationships(xml(entries, 'ppt/_rels/presentation.xml.rels'));
  let order: string[] = [];
  for (const token of scan(xml(entries, 'ppt/presentation.xml'))) {
    if (token.name === 'p:sldId') {
      const target = rels.get(attr(token.raw, 'r:id') ?? '');
      if (target) {
        order.push(resolve('ppt/presentation.xml', target));
      }
    }
  }
  if (order.length === 0) {
    const number = (name: string) => Number(/slide(\d+)\.xml$/.exec(name)?.[1]);
    order = Object.keys(entries)
      .filter(name => /^ppt\/slides\/slide\d+\.xml$/.test(name))
      .sort((a, b) => number(a) - number(b));
  }
  if (order.length === 0) {
    throw new ExtractError('corrupt', 'Not a PowerPoint file');
  }
  const pages: ExtractedPage[] = order.map((path, index) => {
    const {title, lines} = slideText(xml(entries, path));
    const slideRels = relationships(
      xml(entries, path.replace(/slides\//, 'slides/_rels/') + '.rels'),
    );
    let notes = '';
    for (const target of slideRels.values()) {
      if (target.includes('notesSlide')) {
        notes = slideText(xml(entries, resolve(path, target)))
          .lines.filter(line => !/^\d+$/.test(line))
          .join('\n');
      }
    }
    const text = [
      title ? `# ${title}` : '',
      lines.join('\n'),
      notes ? `Notes: ${notes}` : '',
    ]
      .filter(Boolean)
      .join('\n');
    return {page: index + 1, title: title || undefined, text};
  });
  return {
    kind: 'pptx',
    pageLabel: 'slide',
    pages,
    tables: [],
    warnings: cap(pages, limits),
  };
}

// ------------------------------------------------------------------ xlsx

const BUILTIN_DATE_FORMATS = new Set([
  14, 15, 16, 17, 18, 19, 20, 21, 22, 27, 30, 36, 45, 46, 47, 50, 57,
]);

/** For each cell style index: does it show a date? */
function dateStyles(styles: string): boolean[] {
  const custom = new Map<number, boolean>();
  const out: boolean[] = [];
  let inCellXfs = false;
  for (const token of scan(styles)) {
    if (token.name === 'numFmt') {
      const code = (attr(token.raw, 'formatCode') ?? '')
        .replace(/"[^"]*"|\[[^\]]*\]|\\./g, '')
        .toLowerCase();
      custom.set(Number(attr(token.raw, 'numFmtId')), /[dmyhs]/.test(code));
    } else if (token.name === 'cellXfs') {
      inCellXfs = token.open && !token.close;
    } else if (token.name === 'xf' && inCellXfs && token.open) {
      const id = Number(attr(token.raw, 'numFmtId') ?? 0);
      out.push(custom.get(id) ?? BUILTIN_DATE_FORMATS.has(id));
    }
  }
  return out;
}

/** Excel serial day (1900 system, with its leap-year bug) to ISO text. */
export function serialToIso(serial: number, date1904: boolean = false): string {
  const days = date1904 ? serial + 1462 : serial;
  const ms = Math.round((days - 25569) * 86400 * 1000);
  const iso = new Date(ms).toISOString();
  return Number.isInteger(serial)
    ? iso.slice(0, 10)
    : iso.slice(0, 19).replace('T', ' ');
}

function sharedStrings(source: string): string[] {
  const out: string[] = [];
  let current = '';
  let inText = false;
  let phonetic = false;
  for (const token of scan(source)) {
    if (token.name === '') {
      if (inText && !phonetic) {
        current += decodeEntities(token.text!);
      }
    } else if (token.name === 't') {
      inText = token.open && !token.close;
    } else if (token.name === 'rPh') {
      phonetic = token.open && !token.close;
    } else if (token.name === 'si') {
      if (token.open && !token.close) {
        current = '';
      } else {
        out.push(current);
        current = '';
      }
    }
  }
  return out;
}

const columnIndex = (ref: string): number => {
  let n = 0;
  for (let i = 0; i < ref.length; i++) {
    const code = ref.charCodeAt(i);
    if (code < 65 || code > 90) {
      break;
    }
    n = n * 26 + (code - 64);
  }
  return n - 1;
};

function sheetRows(
  source: string,
  strings: string[],
  dates: boolean[],
  date1904: boolean,
  limits: ExtractLimits,
): {rows: string[][]; dropped: number} {
  const rows: string[][] = [];
  let dropped = 0;
  let row: string[] | null = null;
  let type = '';
  let style = 0;
  let column = 0;
  let value = '';
  let capture: '' | 'v' | 't' = '';
  for (const token of scan(source)) {
    if (token.name === '') {
      if (capture) {
        value += token.text!;
      }
      continue;
    }
    switch (token.name) {
      case 'row':
        if (token.open && !token.close) {
          row = [];
        } else if (row) {
          if (row.some(cell => cell !== undefined && cell !== '')) {
            if (rows.length <= limits.maxTableRows) {
              rows.push(Array.from(row, cell => cell ?? ''));
            } else {
              dropped++;
            }
          }
          row = null;
        }
        break;
      case 'c':
        if (token.open) {
          const ref = attr(token.raw, 'r');
          column = ref ? columnIndex(ref) : column + 1;
          type = attr(token.raw, 't') ?? 'n';
          style = Number(attr(token.raw, 's') ?? 0);
          value = '';
        }
        if (
          token.close &&
          !token.open &&
          row &&
          column < limits.maxTableColumns
        ) {
          let text = decodeEntities(value);
          if (type === 's') {
            text = strings[Number(text)] ?? '';
          } else if (type === 'b') {
            text = text === '1' ? 'TRUE' : 'FALSE';
          } else if (type === 'n' && text !== '' && dates[style]) {
            text = serialToIso(Number(text), date1904);
          }
          row[column] = text;
        }
        break;
      case 'v':
        capture = token.open && !token.close ? 'v' : '';
        break;
      case 't':
        capture = token.open && !token.close ? 't' : '';
        break;
      default:
        break;
    }
  }
  return {rows, dropped};
}

export function extractXlsx(
  bytes: Uint8Array,
  limits: ExtractLimits,
): ExtractedDocument {
  const entries = unzip(
    bytes,
    name =>
      /^xl\/(workbook|sharedStrings|styles)\.xml$/.test(name) ||
      name === 'xl/_rels/workbook.xml.rels' ||
      /^xl\/worksheets\/[^/]+\.xml$/.test(name),
  );
  const workbook = xml(entries, 'xl/workbook.xml');
  if (!workbook) {
    throw new ExtractError('corrupt', 'Not an Excel workbook');
  }
  const rels = relationships(xml(entries, 'xl/_rels/workbook.xml.rels'));
  const strings = sharedStrings(xml(entries, 'xl/sharedStrings.xml'));
  const dates = dateStyles(xml(entries, 'xl/styles.xml'));
  const date1904 = /date1904="(1|true)"/.test(workbook);
  const sheets: Array<{name: string; path: string}> = [];
  for (const token of scan(workbook)) {
    if (token.name === 'sheet') {
      const target = rels.get(attr(token.raw, 'r:id') ?? '');
      if (target) {
        sheets.push({
          name: attr(token.raw, 'name') ?? `Sheet${sheets.length + 1}`,
          path: resolve('xl/workbook.xml', target),
        });
      }
    }
  }
  const pages: ExtractedPage[] = [];
  const tables: ExtractedTable[] = [];
  const warnings: string[] = [];
  for (const sheet of sheets) {
    const source = xml(entries, sheet.path);
    if (!source) {
      continue;
    }
    const {rows, dropped} = sheetRows(source, strings, dates, date1904, limits);
    if (rows.length === 0) {
      continue;
    }
    const table = tableFromRows(sheet.name, rows, limits);
    table.truncatedRows += dropped;
    if (table.truncatedRows > 0 && !warnings.includes('table_truncated')) {
      warnings.push('table_truncated');
    }
    tables.push(table);
    pages.push({
      page: pages.length + 1,
      title: sheet.name,
      text: tablePreview(table),
    });
  }
  if (pages.length === 0) {
    throw new ExtractError('empty', 'The workbook has no data');
  }
  return {kind: 'xlsx', pageLabel: 'sheet', pages, tables, warnings};
}
