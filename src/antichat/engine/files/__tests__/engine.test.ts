import fs from 'node:fs';
import path from 'node:path';

import {createFakeEmbedder} from '../../memory/__tests__/support/fakeEmbedder';
import {clearRequestProviders, prepareRequest} from '../../prompt/registry';
import {Db} from '../../store/driver';
import {migrate} from '../../store/schema';
import {openNodeSqlite} from '../../store/__tests__/support/nodeDriver';
import {createFilesEngine, type FilesEngine} from '../engine';
import type {FileIo} from '../native';
import type {FilesRequestMeta} from '../provider';
import {registerFilesMigrations} from '../schema';
import {SqlRejected, prepareSelect} from '../sql';
import {setAudioTranscriber} from '../transcription';

const FIXTURES = path.join(
  __dirname,
  '../../../../../tools/antichat/files/fixtures',
);
const answers = JSON.parse(
  fs.readFileSync(path.join(FIXTURES, 'answers.json'), 'utf8'),
);

/** Node file access; PDFs and OCR are scripted per URI. */
function nodeIo(script: {
  pdf?: Record<string, string[]>;
  ocr?: Record<string, string>;
}): FileIo {
  const file = (uri: string) => path.join(FIXTURES, uri);
  return {
    size: async uri =>
      fs.existsSync(file(uri)) ? fs.statSync(file(uri)).size : 1000,
    readBytes: async (uri, max) => {
      const known = fs.existsSync(file(uri));
      const bytes = known
        ? new Uint8Array(fs.readFileSync(file(uri)))
        : new TextEncoder().encode(uri.endsWith('.pdf') ? '%PDF-1.4' : 'x');
      return max ? bytes.subarray(0, max) : bytes;
    },
    pdfPages: async (uri, start, count) => {
      const pages = script.pdf?.[uri] ?? [];
      return {
        pageCount: pages.length,
        pages: pages.slice(start, start + count),
      };
    },
    ocrImage: async uri => ({
      text: script.ocr?.[uri] ?? '',
      lines: 1,
      confidence: 0.9,
    }),
    ocrPdfPage: async (uri, index) => ({
      text: script.ocr?.[`${uri}#${index}`] ?? '',
      lines: 1,
      confidence: 0.9,
    }),
  };
}

const filler = (page: number) =>
  `Section ${page}. ` +
  'Team leads review the checklist at the start of every shift and record the result in the logbook. '.repeat(
    18,
  );

describe('files engine', () => {
  let db: Db;
  let close: () => void;
  let engine: FilesEngine;
  let vision = false;
  const handbook = Array.from({length: 200}, (_u, index) =>
    index + 1 === 137
      ? `${filler(137)} The access code for the Tromso depot is 7741-K.`
      : filler(index + 1),
  );

  const make = (deviceClass: 'A' | 'C' = 'C', withEmbedder = true) => {
    const embedder = createFakeEmbedder();
    return createFilesEngine({
      db,
      io: nodeIo({
        pdf: {
          'three.pdf': [
            'The daily meal allowance in Lisbon is 47 euros.',
            'Hotel bookings may not exceed 165 euros per night.',
            'Expense reports must be filed within 21 days.',
          ],
          'handbook.pdf': handbook,
          'scan.pdf': ['', ''],
        },
        ocr: {
          'scan.pdf#0': 'Your reference number is HL-58213.',
          'scan.pdf#1': 'Estimated total cost: 640 pounds.',
          'photo.jpg': 'HARBOR ST',
        },
      }),
      deviceClass: () => deviceClass,
      nCtx: () => 8192,
      visionActive: () => vision,
      currentSessionId: () => 's1',
      embedding: withEmbedder
        ? ({
            spec: {id: embedder.id},
            lastUnavailable: null,
            use: async (
              _purpose: string,
              work: (e: typeof embedder) => unknown,
            ) => work(embedder),
            provider: () => async () => embedder,
          } as never)
        : undefined,
    });
  };

  beforeEach(async () => {
    registerFilesMigrations();
    const driver = openNodeSqlite();
    db = new Db(driver);
    close = () => driver.close();
    await migrate(db);
    vision = false;
    engine = make();
    clearRequestProviders();
  });
  afterEach(() => {
    clearRequestProviders();
    setAudioTranscriber(null);
    close();
  });

  const add = (uri: string, sessionId: string | null = 's1') =>
    engine.add({uri, name: uri, sessionId});

  const ask = async (text: string, deviceClass: 'A' | 'C' = 'C') => {
    const provider = engine.providers[0];
    const {registerRequestProvider} = require('../../prompt/registry');
    const remove = registerRequestProvider(provider);
    const prepared = await prepareRequest({
      messages: [{role: 'user', content: text}],
      session: {id: 's1'},
      runtime: {nCtx: 8192, deviceClass},
    });
    remove();
    return {
      prepared,
      system: String(prepared.messages[0].content),
      user: String(prepared.messages[prepared.messages.length - 1].content),
      meta: prepared.meta.files as FilesRequestMeta,
      tools: prepared.tools.map(tool => tool.function.name),
    };
  };

  it('puts a small PDF into the prompt whole, with page marks', async () => {
    const {file} = await add('three.pdf');
    expect(file).toMatchObject({status: 'ready', mode: 'inline', pageCount: 3});
    const {system, meta, tools, user} = await ask('What is the hotel limit?');
    expect(system).toContain(
      '[page 2]\nHotel bookings may not exceed 165 euros',
    );
    expect(system).toContain('(p. 12)');
    expect(meta.inline).toEqual([file.id]);
    expect(meta.excerpts).toEqual([]);
    expect(tools).toEqual([]);
    expect(user).toBe('What is the hotel limit?');
  });

  it('searches a 200-page PDF and hands over the page with the answer', async () => {
    const {file} = await add('handbook.pdf');
    expect(file).toMatchObject({status: 'ready', mode: 'retrieval'});
    expect(file.pageCount).toBe(200);
    expect(file.data.pages).toBeUndefined();
    expect(file.data.embedded).toBeGreaterThan(100);
    const {system, user, meta, tools} = await ask(
      'What is the access code for the Tromso depot?',
    );
    expect(system).not.toContain('7741-K');
    expect(user).toMatch(/\[handbook\.pdf, p\. 137(-138)?\]/);
    expect(user).toContain('7741-K');
    expect(meta.excerpts[0]).toMatchObject({pageStart: 137});
    expect(meta.excerpts.length).toBeLessThanOrEqual(5);
    expect(meta.semantic).toBe(true);
    expect(tools).toEqual(['search_files']);
    // The tool finds it again with other words.
    const result = await engine.tools[0].execute({query: 'Tromso depot code'});
    expect((result as {summary: string}).summary).toContain('p. 137');
  });

  it('class A: keywords only, fewer excerpts, and says so as data', async () => {
    engine = make('A');
    const {file} = await add('handbook.pdf');
    expect(file.data.embedded).toBe(0);
    expect(file.data.limits?.map(l => l.code)).toEqual(
      expect.arrayContaining(['pages_capped', 'keyword_search_only']),
    );
    const {meta} = await ask('access code Tromso depot', 'A');
    expect(meta.semantic).toBe(false);
    expect(meta.excerpts.length).toBeLessThanOrEqual(3);
  });

  it('reads pages without a text layer with OCR', async () => {
    const {file} = await add('scan.pdf');
    expect(file).toMatchObject({status: 'ready', mode: 'ocr', pageCount: 2});
    expect(file.data.ocrPages).toBe(2);
    const {system} = await ask('What is the reference number?');
    expect(system).toContain('HL-58213');
  });

  it('answers spreadsheet questions with SQL, exactly', async () => {
    const {file} = await add('sales.csv');
    expect(file.mode).toBe('table');
    const {system, tools} = await ask('What is the average of units?');
    expect(tools).toEqual(['sql_query']);
    expect(system).toContain('Table sales (400 rows): order_id number');
    const sql = engine.tools[1];
    const agg = answers['sales.aggregates'];
    const average = await sql.execute({
      sql: 'SELECT AVG(units) AS a FROM sales;',
    });
    expect((average as {summary: string}).summary).toContain(
      String(agg.average_units),
    );
    const top = await sql.execute({
      sql: 'SELECT region, SUM(units * unit_price) AS revenue FROM sales GROUP BY region ORDER BY revenue DESC LIMIT 1',
    });
    expect((top as {summary: string}).summary).toContain(
      agg.top_region_by_revenue,
    );
    // xlsx: both sheets become tables.
    await add('sales.xlsx');
    const count = await sql.execute({sql: 'select count(*) from orders'});
    expect((count as {summary: string}).summary).toContain('400');
  });

  it('lets SQL read nothing but the imported tables', async () => {
    await add('sales.csv');
    const tables = await engine.store.tables(
      (await engine.store.list('s1')).map(f => f.id),
    );
    for (const bad of [
      'DELETE FROM sales',
      'SELECT * FROM sales; DROP TABLE sales',
      'SELECT * FROM memories',
      'SELECT * FROM sales, files',
      'SELECT name FROM sqlite_master',
      'PRAGMA table_info(sales)',
    ]) {
      const result = await engine.tools[1].execute({sql: bad});
      expect((result as {summary: string}).summary).toMatch(
        /allowed|Unknown table|listed tables/,
      );
    }
    expect(() => prepareSelect('UPDATE sales SET units = 1', tables)).toThrow(
      SqlRejected,
    );
    expect(prepareSelect("SELECT 'sales' FROM sales", tables)).toBe(
      `SELECT 'sales' FROM ${tables[0].sqlName}`,
    );
  });

  it('images: OCR text without a vision model, the image itself with one', async () => {
    let {file} = await add('photo.jpg');
    expect(file).toMatchObject({status: 'ready', mode: 'ocr'});
    expect(file.data.limits?.map(l => l.code)).toContain('vision_unavailable');
    expect(await engine.imageUris('s1')).toEqual([]);
    expect((await ask('What does the sign say?')).system).toContain(
      'HARBOR ST',
    );
    await engine.remove(file.id);
    vision = true;
    ({file} = await add('photo.jpg'));
    expect(file.mode).toBe('vision');
    expect(await engine.imageUris('s1')).toEqual(['photo.jpg']);
    expect((await ask('What is in the picture?')).meta.images).toEqual([
      file.id,
    ]);
  });

  it("adopts the new chat's drafts and forgets a deleted chat's files", async () => {
    await add('three.pdf', null);
    expect(await engine.store.list('s1')).toHaveLength(0);
    const {meta} = await ask('hotel limit');
    expect(meta.inline).toHaveLength(1);
    await add('sales.csv');
    await engine.removeForSession('s1');
    expect(await engine.store.list('s1')).toHaveLength(0);
    expect(await db.all('SELECT * FROM chunks')).toEqual([]);
    expect(await db.all('SELECT * FROM file_tables')).toEqual([]);
  });

  it('refuses what it cannot use, with a reason as data', async () => {
    const audio = await engine.add({
      uri: 'a.m4a',
      name: 'a.m4a',
      sessionId: 's1',
    });
    expect(audio.file.status).toBe('failed');
    expect(audio.file.data.limits?.[0]).toMatchObject({
      code: 'audio_unavailable',
      severity: 'blocked',
    });
    const big = await engine.add({
      uri: 'x.pdf',
      name: 'x.pdf',
      sizeBytes: 900 * 1024 * 1024,
      sessionId: 's1',
    });
    expect(big.file.data.limits?.[0].code).toBe('file_too_large');
    // With a transcriber registered, audio is a document like any other.
    setAudioTranscriber({
      available: () => true,
      transcribe: async () => ({
        durationSec: 70,
        segments: [
          {startSec: 2, endSec: 8, text: 'Welcome to the budget meeting.'},
          {startSec: 62, endSec: 69, text: 'The total is 380,000 euros.'},
        ],
      }),
    });
    const ok = await engine.add({uri: 'b.m4a', name: 'b.m4a', sessionId: 's1'});
    expect(ok.file).toMatchObject({
      status: 'ready',
      mode: 'audio',
      pageCount: 2,
    });
  });
});
