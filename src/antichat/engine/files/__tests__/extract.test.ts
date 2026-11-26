import fs from 'node:fs';
import path from 'node:path';

import {chunkDocument, estimateTokens} from '../chunk';
import {
  detectKind,
  extractCsv,
  extractFromBytes,
  htmlToText,
  normalizePdfText,
  parseDelimited,
  rtfToText,
  decodeText,
  serialToIso,
  type ExtractLimits,
} from '../extract';

const FIXTURES = path.join(
  __dirname,
  '../../../../../tools/antichat/files/fixtures',
);
const read = (name: string) =>
  new Uint8Array(fs.readFileSync(path.join(FIXTURES, name)));
const answers = JSON.parse(
  fs.readFileSync(path.join(FIXTURES, 'answers.json'), 'utf8'),
);
const limits: ExtractLimits = {
  maxChars: 2_000_000,
  maxTableRows: 50_000,
  maxTableColumns: 64,
};

describe('detectKind', () => {
  it('trusts magic bytes over the name', () => {
    expect(detectKind({name: 'x.txt', head: read('three-pages.pdf')})).toBe(
      'pdf',
    );
    expect(detectKind({name: 'a.docx', head: read('report.docx')})).toBe(
      'docx',
    );
    expect(detectKind({name: 'main.kt'})).toBe('code');
    expect(detectKind({name: 'voice.m4a'})).toBe('audio');
    expect(detectKind({name: 'IMG_1.HEIC'})).toBe('image');
    expect(detectKind({name: 'blob'})).toBe('unknown');
  });
});

describe('text formats', () => {
  it('decodes UTF-8, UTF-16 and Latin-1', () => {
    expect(decodeText(new Uint8Array([0xc3, 0xa4, 0x62]))).toBe('äb');
    expect(decodeText(new Uint8Array([0xff, 0xfe, 0x68, 0, 0x69, 0]))).toBe(
      'hi',
    );
    expect(decodeText(new Uint8Array([0xe4, 0x62]))).toBe('äb');
  });

  it('reads HTML and RTF as text', () => {
    expect(
      htmlToText(
        '<html><style>p{}</style><h1>Title</h1><p>A &amp; B</p><ul><li>one</li></ul>',
      ),
    ).toBe('# Title\n\nA & B\n\n- one');
    expect(
      rtfToText(
        "{\\rtf1{\\fonttbl{\\f0 Arial;}}\\f0 Caf\\'e9 \\u8364? 5\\par Next}",
      ),
    ).toBe('Café € 5\nNext');
  });

  it('repairs PDF line wraps and hyphenation', () => {
    expect(
      normalizePdfText(
        'The quick brown fox jumps over the la-\nzy dog and\nruns.\n\n- item one\n- item two',
      ),
    ).toBe(
      'The quick brown fox jumps over the lazy dog and runs.\n\n- item one\n- item two',
    );
  });
});

describe('CSV', () => {
  it('parses quotes, embedded newlines and sniffs the delimiter', () => {
    expect(parseDelimited('a;b\n"x;1";"say ""hi""\nthere"\n')).toEqual([
      ['a', 'b'],
      ['x;1', 'say "hi"\nthere'],
    ]);
  });

  it('types columns only when the whole column agrees', () => {
    const doc = extractCsv(
      'id,amount,de,zip\n1,"1,234.5","1.234,5",01234\n2,7,"3,25",99999\n',
      limits,
    );
    expect(doc.tables[0].rows).toEqual([
      [1, 1234.5, 1234.5, '01234'],
      [2, 7, 3.25, '99999'],
    ]);
  });

  it('reads the sales fixture exactly', () => {
    const doc = extractFromBytes(
      read('sales.csv'),
      {name: 'sales.csv'},
      limits,
    );
    const table = doc.tables[0];
    expect(table.columns).toEqual([
      'order_id',
      'date',
      'region',
      'product',
      'units',
      'unit_price',
    ]);
    const units = table.rows.map(row => row[4] as number);
    const agg = answers['sales.aggregates'];
    expect(table.rows.length).toBe(agg.row_count);
    expect(units.reduce((a, b) => a + b, 0)).toBe(agg.sum_units);
  });
});

describe('Office files', () => {
  it('docx: headings, table, list and the page break', () => {
    const doc = extractFromBytes(read('report.docx'), {name: 'r.docx'}, limits);
    expect(doc.pageLabel).toBe('page');
    expect(doc.pages).toHaveLength(2);
    expect(doc.pages[0].text).toContain('# Summary');
    expect(doc.pages[0].text).toContain('4.2 million kroner');
    expect(doc.pages[0].text).toContain('| Bergen | 1.9 | 14 |');
    expect(doc.pages[1].text).toContain('3 February');
    expect(doc.pages[1].text).toContain('- First item');
  });

  it('pptx: one page per slide, in order, with notes', () => {
    const doc = extractFromBytes(read('deck.pptx'), {name: 'd.pptx'}, limits);
    expect(doc.pageLabel).toBe('slide');
    expect(doc.pages.map(page => page.title)).toEqual([
      'Project Heron kickoff',
      'Timeline',
      'Budget',
      'Risks',
    ]);
    expect(doc.pages[2].text).toContain('380,000 euros');
    expect(doc.pages[2].text).toContain('Notes: Finance signed off last week.');
  });

  it('xlsx: sheets as tables, numbers typed, dates as ISO text', () => {
    const doc = extractFromBytes(read('sales.xlsx'), {name: 's.xlsx'}, limits);
    expect(doc.tables.map(table => table.name)).toEqual(['Orders', 'Prices']);
    const csv = extractFromBytes(read('sales.csv'), {name: 's.csv'}, limits);
    expect(doc.tables[0].columns).toEqual(csv.tables[0].columns);
    expect(doc.tables[0].rows).toEqual(csv.tables[0].rows);
    expect(serialToIso(46027)).toBe('2026-01-05');
  });

  it('reports a broken archive as corrupt', () => {
    expect(() =>
      extractFromBytes(
        new Uint8Array([0x50, 0x4b, 3, 4, 1, 2, 3]),
        {name: 'x.docx'},
        limits,
      ),
    ).toThrow(/could not be opened/);
  });
});

describe('chunkDocument', () => {
  const pages = Array.from({length: 12}, (_unused, index) => ({
    page: index + 1,
    text: `Page ${index + 1} starts here. ${'Lorem ipsum dolor sit amet, consectetur. '.repeat(30)}MARK${index + 1}.`,
  }));
  const doc = {
    kind: 'pdf' as const,
    pageLabel: 'page' as const,
    pages,
    tables: [],
    warnings: [],
  };

  it('keeps chunks near the target size and maps pages exactly', () => {
    const chunks = chunkDocument(doc, {targetTokens: 200});
    expect(chunks.length).toBeGreaterThan(12);
    for (const chunk of chunks) {
      expect(estimateTokens(chunk.text)).toBeLessThanOrEqual(210);
      expect(chunk.pageEnd).toBeGreaterThanOrEqual(chunk.pageStart);
      for (const m of chunk.text.matchAll(/MARK(\d+)\./g)) {
        expect(Number(m[1])).toBeGreaterThanOrEqual(chunk.pageStart);
        expect(Number(m[1])).toBeLessThanOrEqual(chunk.pageEnd);
      }
      for (const m of chunk.text.matchAll(/Page (\d+) starts here/g)) {
        expect(Number(m[1])).toBeGreaterThanOrEqual(chunk.pageStart);
        expect(Number(m[1])).toBeLessThanOrEqual(chunk.pageEnd);
      }
    }
    // Every page is covered and the order is stable.
    expect(new Set(chunks.flatMap(c => [c.pageStart, c.pageEnd])).size).toBe(
      12,
    );
    expect(chunkDocument(doc, {targetTokens: 200})).toEqual(chunks);
  });

  it('overlaps neighbours', () => {
    const chunks = chunkDocument(doc, {targetTokens: 200});
    const tail = chunks[0].text.slice(-40);
    expect(chunks[1].text).toContain(tail);
  });
});
