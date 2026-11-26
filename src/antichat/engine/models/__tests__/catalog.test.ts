import raw from '../catalog/bundled.json';
import {bundledCatalog} from '../catalog/bundledCatalog';
import {
  fileUrl,
  filesFor,
  getClass,
  getModel,
  isRevoked,
  localFileName,
  totalBytes,
  weightsFor,
} from '../catalog/lookup';
import {CatalogError, parseCatalog} from '../catalog/parse';
import {CatalogModel, DEVICE_CLASSES} from '../catalog/types';

const clone = (): any => JSON.parse(JSON.stringify(raw));
const model = (id: string) => getModel(bundledCatalog, id) as CatalogModel;
const smallest = (m: CatalogModel) =>
  Math.min(...m.files.map(f => f.sizeBytes));

describe('bundled catalogue', () => {
  it('parses and has all five classes', () => {
    expect(bundledCatalog.schemaVersion).toBe(1);
    expect(bundledCatalog.classes.map(c => c.id)).toEqual([...DEVICE_CLASSES]);
    expect(bundledCatalog.expiresAt).toBeNull();
  });

  it('holds the candidates from the research with exact file names', () => {
    const names = bundledCatalog.models.flatMap(m =>
      m.files.map(f => `${f.repo}/${f.path}`),
    );
    expect(names).toEqual(
      expect.arrayContaining([
        'LiquidAI/LFM3-1.7B-GGUF/LFM3-1.7B-Q4_K_M.gguf',
        'unsloth/gemma-4-E2B-it-qat-GGUF/gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf',
        'unsloth/gemma-4-E4B-it-qat-GGUF/gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf',
        'unsloth/Qwen3.5-9B-GGUF/Qwen3.5-9B-Q4_K_M.gguf',
      ]),
    );
  });

  it('matches the sizes and hashes of the files we hold locally', () => {
    // Cross-checked on 2026-11-24: Hugging Face API == shasum of the download.
    const e2b = model('gemma-4-e2b-qat');
    expect(e2b.files[0].sizeBytes).toBe(2620370976);
    expect(e2b.files[0].sha256).toBe(
      'e531007218dfab990486a5de7676a6932d6ea8dea233d1f698d7c21cf8a16889',
    );
    expect(e2b.projector?.sizeBytes).toBe(985654080);
    expect(model('qwen3.5-9b').files[0].sizeBytes).toBe(5680522464);
  });

  it('orders both ladders from largest to smallest', () => {
    for (const ladder of [
      bundledCatalog.ladder,
      bundledCatalog.unrestrictedLadder,
    ]) {
      const sizes = ladder.map(id => smallest(model(id)));
      expect(sizes).toEqual([...sizes].sort((a, b) => b - a));
    }
  });

  it('gives bigger classes a default at least as big', () => {
    const sizes = bundledCatalog.classes.map(c =>
      smallest(model(c.defaultModel)),
    );
    expect(sizes).toEqual([...sizes].sort((a, b) => a - b));
  });

  it('raises class requirements monotonically', () => {
    const classes = bundledCatalog.classes;
    for (let i = 1; i < classes.length; i++) {
      const [prev, cur] = [classes[i - 1].requires, classes[i].requires];
      expect(cur.ios.weightsPoolBytes).toBeGreaterThan(
        prev.ios.weightsPoolBytes,
      );
      expect(cur.ios.dirtyPoolBytes).toBeGreaterThan(prev.ios.dirtyPoolBytes);
      expect(cur.android.poolBytes).toBeGreaterThan(prev.android.poolBytes);
    }
    // Class A is the floor: every phone qualifies.
    expect(classes[0].requires.android.poolBytes).toBe(0);
  });

  it('marks unrestricted models and links them to their base', () => {
    const addOns = bundledCatalog.models.filter(m => m.unrestricted);
    // The two variants the Mac evaluation found worth offering stay on the
    // ladder; every other one is a store-only counterpart of a standard size.
    expect(bundledCatalog.unrestrictedLadder).toEqual([
      'gemma-4-e4b-unrestricted',
      'qwen3.5-4b-unrestricted',
    ]);
    expect(addOns.length).toBeGreaterThanOrEqual(20);
    for (const addOn of addOns) {
      expect(addOn.baseModel && model(addOn.baseModel).unrestricted).toBe(
        false,
      );
    }
    expect(bundledCatalog.classes.map(c => c.unrestrictedModel)).toEqual([
      null,
      null,
      'qwen3.5-4b-unrestricted',
      'gemma-4-e4b-unrestricted',
      'gemma-4-e4b-unrestricted',
    ]);
  });

  it('records licences, and says LFM3 is not open source', () => {
    expect(model('lfm3-1.7b').licence.openSource).toBe(false);
    expect(model('lfm3-1.7b').licence.notice).toMatch(/\$10M/);
    expect(model('gemma-4-e2b-qat').licence.id).toBe('Apache-2.0');
    // Qwen3.5-0.8B failed the evaluation and is not offered at all.
    expect(bundledCatalog.models.some(m => m.id === 'qwen3.5-0.8b')).toBe(
      false,
    );
  });

  it('keeps thinking off by default everywhere', () => {
    expect(
      bundledCatalog.models.every(m => m.template.thinking.default === false),
    ).toBe(true);
  });

  it('gives every vision model a projector with a hash', () => {
    for (const m of bundledCatalog.models.filter(x => x.capabilities.vision)) {
      expect(m.projector?.sha256).toMatch(/^[0-9a-f]{64}$/);
    }
  });
});

describe('lookup helpers', () => {
  it('picks the Q4_0 file for OpenCL and Q4_K_M otherwise', () => {
    const qwen = model('qwen3.5-4b');
    expect(weightsFor(qwen, 'opencl').quant).toBe('Q4_0');
    expect(weightsFor(qwen, 'metal').quant).toBe('Q4_K_M');
    expect(weightsFor(qwen, 'cpu').quant).toBe('Q4_K_M');
  });

  it('falls back to a file without backends, then to the first file', () => {
    const base = model('qwen3.5-4b');
    const noBackends = {
      ...base,
      files: [{...base.files[0], backends: undefined}],
    };
    expect(weightsFor(noBackends, 'opencl')).toBe(noBackends.files[0]);
    const metalOnly = {
      ...base,
      files: [{...base.files[0], backends: ['metal' as const]}],
    };
    expect(weightsFor(metalOnly, 'opencl')).toBe(metalOnly.files[0]);
  });

  it('builds a pinned Hugging Face address', () => {
    const file = model('lfm3-1.7b').files[0];
    expect(fileUrl(file)).toBe(
      `https://huggingface.co/${file.repo}/resolve/${file.revision}/${file.path}`,
    );
    expect(file.revision).toMatch(/^[0-9a-f]{40}$/);
  });

  it('keeps local names unique where repositories reuse "mmproj-F16.gguf"', () => {
    const names = bundledCatalog.models
      .filter(m => m.projector)
      .map(m => localFileName(m.projector!));
    const distinctFiles = new Set(
      bundledCatalog.models
        .filter(m => m.projector)
        .map(m => m.projector!.sha256),
    );
    expect(new Set(names).size).toBe(distinctFiles.size);
    expect(names[0]).not.toContain('/');
  });

  it('lists files with and without the projector', () => {
    const e2b = model('gemma-4-e2b-qat');
    expect(filesFor(e2b, 'metal', false)).toHaveLength(1);
    const withVision = filesFor(e2b, 'metal', true);
    expect(withVision).toHaveLength(2);
    expect(totalBytes(withVision)).toBe(2620370976 + 985654080);
    // A text-only model has nothing to add.
    expect(filesFor(model('lfm3-1.7b'), 'cpu', true)).toHaveLength(1);
  });

  it('revokes by model id, weights hash or projector hash', () => {
    const e2b = model('gemma-4-e2b-qat');
    const withRevoked = (entry: string) => ({
      ...bundledCatalog,
      revoked: [entry],
    });
    expect(isRevoked(bundledCatalog, e2b)).toBe(false);
    expect(isRevoked(withRevoked(e2b.id), e2b)).toBe(true);
    expect(isRevoked(withRevoked(e2b.files[0].sha256), e2b)).toBe(true);
    expect(isRevoked(withRevoked(e2b.projector!.sha256), e2b)).toBe(true);
    expect(isRevoked(withRevoked('something-else'), e2b)).toBe(false);
  });

  it('finds classes', () => {
    expect(getClass(bundledCatalog, 'C').defaultModel).toBe('gemma-4-e2b-qat');
    expect(getModel(bundledCatalog, 'nope')).toBeUndefined();
  });
});

/** A model entry that has a projector. */
const vision = (doc: any) =>
  doc.models.find((m: any) => m.id === 'gemma-4-e2b-qat');

describe('parseCatalog', () => {
  it('round-trips the bundled document', () => {
    expect(parseCatalog(clone())).toEqual(bundledCatalog);
  });

  it('drops unknown fields', () => {
    const doc = clone();
    doc.futureField = {a: 1};
    doc.models[0].futureField = true;
    expect(parseCatalog(doc)).toEqual(bundledCatalog);
  });

  it('treats a missing revoked list as empty', () => {
    const doc = clone();
    delete doc.revoked;
    expect(parseCatalog(doc).revoked).toEqual([]);
  });

  const broken: Array<[string, (doc: any) => void, RegExp]> = [
    ['not an object', doc => (doc.models = 'x'), /models: expected an array/],
    ['newer schema', doc => (doc.schemaVersion = 2), /schemaVersion 2/],
    ['fractional serial', doc => (doc.serial = 1.5), /serial/],
    ['missing policy', doc => delete doc.policy, /policy: expected an object/],
    ['empty id', doc => (doc.models[0].id = ''), /models\[0\]\.id/],
    ['bad hash', doc => (doc.models[0].files[0].sha256 = 'ABC'), /sha256/],
    ['bad repo', doc => (doc.models[0].files[0].repo = 'evil'), /repo/],
    [
      'path escape',
      doc => (doc.models[0].files[0].path = '../x.gguf'),
      /relative path/,
    ],
    [
      'absolute path',
      doc => (doc.models[0].files[0].path = '/x.gguf'),
      /relative path/,
    ],
    [
      'unpinned revision',
      doc => (doc.models[0].files[0].revision = 'main'),
      /commit id/,
    ],
    ['zero size', doc => (doc.models[0].files[0].sizeBytes = 0), /sizeBytes/],
    ['no files', doc => (doc.models[0].files = []), /at least one file/],
    [
      'unknown backend',
      doc => (doc.models[0].files[0].backends = ['vulkan']),
      /backends\[0\]/,
    ],
    [
      'vision without projector',
      doc => delete vision(doc).projector,
      /projector for a vision model/,
    ],
    [
      'bad modality',
      doc => (vision(doc).projector.modalities = ['smell']),
      /modalities/,
    ],
    ['bad tier', doc => (doc.models[0].tier = 'Z'), /tier/],
    ['bad flag', doc => (doc.models[0].unrestricted = 'no'), /a boolean/],
    ['negative memory', doc => (doc.models[0].memory.fixedBytes = -1), /fixed/],
    ['duplicate id', doc => (doc.models[1].id = doc.models[0].id), /duplicate/],
    [
      'ladder names an unknown model',
      doc => doc.ladder.push('ghost'),
      /unknown model "ghost"/,
    ],
    ['empty ladder', doc => (doc.ladder = []), /at least one model/],
    [
      'unrestricted model on the standard ladder',
      doc => doc.ladder.push('qwen3.5-4b-unrestricted'),
      /must not be unrestricted/,
    ],
    [
      'standard model as the add-on',
      doc => (doc.classes[0].unrestrictedModel = 'lfm3-1.7b'),
      /must be unrestricted/,
    ],
    [
      'default off the ladder',
      doc => (doc.classes[1].defaultModel = 'qwen3.5-2b'),
      /must be on the ladder/,
    ],
    [
      'add-on off its ladder',
      doc => (doc.unrestrictedLadder = ['gemma-4-e4b-unrestricted']),
      /unrestricted ladder/,
    ],
    ['missing class', doc => doc.classes.pop(), /exactly A, B, C, D, E/],
    [
      'unknown upgrade',
      doc => (doc.classes[1].upgrade.modelId = 'ghost'),
      /upgrade\.modelId/,
    ],
    [
      'bad upgrade mode',
      doc => (doc.classes[1].upgrade.mode = 'force'),
      /upgrade\.mode/,
    ],
    [
      'unknown base model',
      doc => (doc.models[doc.models.length - 1].baseModel = 'ghost'),
      /baseModel/,
    ],
    [
      'open-ended steps missing',
      doc => (doc.policy.ios.availableFloor[2].maxRamBytes = 5),
      /maxRamBytes: null/,
    ],
    ['bad tier cap', doc => (doc.policy.tierCap.mid = 'Q'), /tierCap\.mid/],
    [
      'overhead below one',
      doc => (doc.policy.android.overheadFactor = 0.5),
      /android/,
    ],
  ];

  it.each(broken)('rejects: %s', (_name, mutate, message) => {
    const doc = clone();
    mutate(doc);
    expect(() => parseCatalog(doc)).toThrow(CatalogError);
    expect(() => parseCatalog(doc)).toThrow(message);
  });

  it('rejects non-objects outright', () => {
    expect(() => parseCatalog(null)).toThrow(CatalogError);
    expect(() => parseCatalog([])).toThrow(CatalogError);
  });

  it('accepts an upgrade without an extra floor and with a partial one', () => {
    const doc = clone();
    expect(parseCatalog(doc).classes[1].upgrade).toEqual({
      modelId: 'gemma-4-e2b-qat',
      mode: 'offer',
    });
    doc.classes[1].upgrade.minMeasuredAvailableBytes = {android: 5};
    expect(
      parseCatalog(doc).classes[1].upgrade?.minMeasuredAvailableBytes,
    ).toEqual({ios: undefined, android: 5});
  });

  it('carries model-card languages, inherited by unrestricted variants', () => {
    expect(model('ministral-3-3b').languages?.codes).toContain('nl');
    expect(model('qwen3.5-2b').languages).toMatchObject({count: 201});
    expect(model('gemma-4-e2b-qat').languages).toMatchObject({
      count: 140,
      atLeast: true,
    });
    expect(model('deepseek-r1-qwen-1.5b').languages).toBeUndefined();
    for (const m of bundledCatalog.models) {
      if (m.baseModel) {
        expect(m.languages).toEqual(model(m.baseModel).languages);
      }
    }
  });

  it('rejects a languages block with neither codes nor a count', () => {
    const doc = JSON.parse(JSON.stringify(bundledCatalog));
    doc.models[0].languages = {source: 'x/y'};
    expect(() => parseCatalog(doc)).toThrow(CatalogError);
    doc.models[0].languages = {codes: ['English'], source: 'x/y'};
    expect(() => parseCatalog(doc)).toThrow(CatalogError);
  });
});
