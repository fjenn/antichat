/**
 * CSV and friends: RFC 4180 parsing, delimiter sniffing, typed cells.
 */
import {ExtractError} from './types';
import type {
  Cell,
  ExtractedDocument,
  ExtractedTable,
  ExtractLimits,
} from './types';

export function sniffDelimiter(text: string): string {
  const sample = text.slice(0, 4000).split(/\r?\n/).slice(0, 8);
  let best = ',';
  let bestScore = 0;
  for (const candidate of [',', ';', '\t', '|']) {
    const counts = sample
      .filter(line => line.length > 0)
      .map(line => line.split(candidate).length - 1);
    if (counts.length === 0 || counts[0] === 0) {
      continue;
    }
    const steady = counts.filter(count => count === counts[0]).length;
    const score = counts[0] * steady;
    if (score > bestScore) {
      bestScore = score;
      best = candidate;
    }
  }
  return best;
}

export function parseDelimited(
  text: string,
  options: {delimiter?: string; maxRows?: number} = {},
): string[][] {
  const delimiter = options.delimiter ?? sniffDelimiter(text);
  const rows: string[][] = [];
  let row: string[] = [];
  let field = '';
  let quoted = false;
  let i = text.charCodeAt(0) === 0xfeff ? 1 : 0;
  const endRow = () => {
    row.push(field);
    field = '';
    if (row.length > 1 || row[0] !== '') {
      rows.push(row);
    }
    row = [];
  };
  for (; i < text.length; i++) {
    const ch = text[i];
    if (quoted) {
      if (ch === '"') {
        if (text[i + 1] === '"') {
          field += '"';
          i++;
        } else {
          quoted = false;
        }
      } else {
        field += ch;
      }
    } else if (ch === '"' && field === '') {
      quoted = true;
    } else if (ch === delimiter) {
      row.push(field);
      field = '';
    } else if (ch === '\n' || ch === '\r') {
      if (ch === '\r' && text[i + 1] === '\n') {
        i++;
      }
      endRow();
      if (options.maxRows && rows.length >= options.maxRows) {
        return rows;
      }
    } else {
      field += ch;
    }
  }
  if (field !== '' || row.length > 0) {
    endRow();
  }
  return rows;
}

const PLAIN = /^[-+]?\d+(\.\d+)?([eE][-+]?\d+)?$/;
const US = /^[-+]?\d{1,3}(,\d{3})+(\.\d+)?$/;
const EU = /^[-+]?\d{1,3}(\.\d{3})+(,\d+)?$/;
const EU_DECIMAL = /^[-+]?\d+,\d+$/;

/** Numbers where the whole column agrees on a format; text otherwise. */
export function typeColumns(rows: string[][], width: number): Cell[][] {
  const out: Cell[][] = rows.map(() => new Array<Cell>(width).fill(null));
  for (let c = 0; c < width; c++) {
    const values = rows.map(row => (row[c] ?? '').trim());
    const filled = values.filter(value => value !== '');
    const all = (re: RegExp) =>
      filled.length > 0 && filled.every(v => re.test(v));
    const some = (re: RegExp) => filled.some(v => re.test(v));
    let convert: ((value: string) => Cell) | null = null;
    if (all(PLAIN) && !filled.some(v => /^0\d/.test(v))) {
      convert = Number;
    } else if (filled.every(v => PLAIN.test(v) || US.test(v)) && some(US)) {
      convert = value => Number(value.replace(/,/g, ''));
    } else if (
      filled.length > 0 &&
      filled.every(
        v => EU.test(v) || EU_DECIMAL.test(v) || /^[-+]?\d+$/.test(v),
      ) &&
      (some(EU_DECIMAL) || filled.some(v => /,\d+$/.test(v)))
    ) {
      convert = value => Number(value.replace(/\./g, '').replace(',', '.'));
    }
    values.forEach((value, r) => {
      out[r][c] = value === '' ? null : convert ? convert(value) : value;
    });
  }
  return out;
}

/** Header names that are valid, unique and never empty. */
export function cleanHeaders(header: string[], width: number): string[] {
  const seen = new Map<string, number>();
  const out: string[] = [];
  for (let i = 0; i < width; i++) {
    let name = (header[i] ?? '').trim().replace(/\s+/g, ' ') || `col_${i + 1}`;
    const count = seen.get(name.toLowerCase()) ?? 0;
    seen.set(name.toLowerCase(), count + 1);
    if (count > 0) {
      name = `${name}_${count + 1}`;
    }
    out.push(name);
  }
  return out;
}

export function tableFromRows(
  name: string,
  raw: string[][],
  limits: ExtractLimits,
): ExtractedTable {
  const width = Math.min(
    limits.maxTableColumns,
    raw.reduce((max, row) => Math.max(max, row.length), 0),
  );
  const body = raw.slice(1);
  const kept = body.slice(0, limits.maxTableRows);
  return {
    name,
    columns: cleanHeaders(raw[0] ?? [], width),
    rows: typeColumns(kept, width),
    truncatedRows: body.length - kept.length,
  };
}

/** A short text view of a table: header and the first rows. */
export function tablePreview(table: ExtractedTable, rows: number = 20): string {
  const line = (cells: Cell[]) =>
    cells.map(cell => (cell === null ? '' : String(cell))).join(', ');
  const total = table.rows.length + table.truncatedRows;
  return [
    `Table "${table.name}": ${total} rows, columns: ${table.columns.join(', ')}`,
    line(table.columns),
    ...table.rows.slice(0, rows).map(line),
    total > rows ? `… (${total - rows} more rows)` : '',
  ]
    .filter(Boolean)
    .join('\n');
}

export function extractCsv(
  text: string,
  limits: ExtractLimits,
  name: string = 'data',
): ExtractedDocument {
  const raw = parseDelimited(text);
  if (raw.length === 0) {
    throw new ExtractError('empty', 'The file has no rows');
  }
  const table = tableFromRows(name, raw, limits);
  return {
    kind: 'csv',
    pageLabel: 'sheet',
    pages: [{page: 1, title: name, text: tablePreview(table)}],
    tables: [table],
    warnings: table.truncatedRows > 0 ? ['table_truncated'] : [],
  };
}
