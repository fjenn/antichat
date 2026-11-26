import {bundledCatalog} from '../catalog/bundledCatalog';
import {getModel} from '../catalog/lookup';
import type {Catalog, CatalogModel} from '../catalog/types';
import {dirtyBytesFor, fitModel, weightsBytesFor} from '../policy/fit';
import {
  bestShapeFor,
  contextCandidates,
  selectModel,
  selectUnrestricted,
  stepDown,
} from '../policy/select';

import {android, GB, ios, MB, PHONE, profile} from './fixtures/devices';

const catalog = bundledCatalog;
const model = (id: string) => getModel(catalog, id) as CatalogModel;

describe('fit check', () => {
  const e2b = model('gemma-4-e2b-qat');
  const shape = {contextSize: 8192, vision: true, backend: 'metal' as const};

  it('adds up weights and working memory', () => {
    expect(weightsBytesFor(e2b, shape)).toBe(2620370976 + 985654080);
    expect(weightsBytesFor(e2b, {...shape, vision: false})).toBe(2620370976);
    expect(dirtyBytesFor(e2b, shape, catalog.policy)).toBe(
      12288 * 8192 + 300 * MB + 256 * MB,
    );
    expect(dirtyBytesFor(e2b, {...shape, vision: false}, catalog.policy)).toBe(
      12288 * 8192 + 300 * MB,
    );
  });

  it('checks the two iOS pools separately', () => {
    const ok = fitModel(e2b, shape, PHONE.C().budget, catalog.policy);
    expect(ok).toMatchObject({fits: true, problems: []});

    // 6 GB iPhone: model plus projector is more than 55% of RAM.
    const tooHeavy = fitModel(e2b, shape, PHONE.B().budget, catalog.policy);
    expect(tooHeavy.problems).toEqual(['weights']);

    // Plenty of RAM, almost none of it available to the app.
    const starved = fitModel(
      e2b,
      shape,
      profile(ios(11.45, 0.9)).budget,
      catalog.policy,
    );
    expect(starved.problems).toEqual(['working_memory']);
  });

  it('honours the measured-memory floor from the catalogue', () => {
    const strict: CatalogModel = {
      ...e2b,
      memory: {
        ...e2b.memory,
        minMeasuredAvailableBytes: {ios: 4 * GB, android: 4 * GB},
      },
    };
    const result = fitModel(strict, shape, PHONE.C().budget, catalog.policy);
    expect(result.problems).toEqual(['below_measured_floor']);
  });

  it('checks the sum against the single Android pool, with overhead', () => {
    const budget = profile(android(7.4, 3)).budget;
    const cl = {...shape, backend: 'opencl' as const};
    expect(fitModel(e2b, cl, budget, catalog.policy).fits).toBe(true);
    const nineB = fitModel(model('qwen3.5-9b'), cl, budget, catalog.policy);
    expect(nineB.fits).toBe(false);
    expect(nineB.problems).toContain('weights');
    // OpenCL uses the smaller Q4_0 file.
    expect(nineB.weightsBytes).toBe(5379417312 + 918166080);
  });

  it('names working memory when the context is the larger part', () => {
    const tiny = model('lfm3-1.7b');
    const huge = {contextSize: 262144, vision: false, backend: 'cpu' as const};
    const result = fitModel(
      tiny,
      huge,
      profile(android(7.4, 3)).budget,
      catalog.policy,
    );
    expect(result.problems).toEqual(['working_memory']);
  });
});

describe('default model per class', () => {
  it.each([
    ['A', PHONE.A, 'lfm3-1.7b', 4096, false],
    ['B', PHONE.B, 'lfm3-1.7b', 8192, false],
    ['C', PHONE.C, 'gemma-4-e2b-qat', 8192, true],
    ['D', PHONE.D, 'gemma-4-e4b-qat', 16384, true],
    ['E', PHONE.E, 'qwen3.5-9b', 16384, true],
  ] as const)('class %s', (cls, phone, id, contextSize, vision) => {
    const selection = selectModel(phone(), catalog);
    expect(selection.deviceClass).toBe(cls);
    expect(selection.model.id).toBe(id);
    expect(selection.reason).toBe('class_default');
    expect(selection.shape).toMatchObject({contextSize, vision});
    expect(selection.fit.fits).toBe(true);
    expect(selection.skipped).toEqual([]);
  });

  it('downloads the projector with the model only where vision is on', () => {
    expect(selectModel(PHONE.C(), catalog).files.map(f => f.path)).toEqual([
      'gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf',
      'mmproj-F16.gguf',
    ]);
    const b = selectModel(PHONE.B(), catalog);
    expect(b.files).toHaveLength(1);
    expect(b.downloadBytes).toBe(1099627808);
  });

  it('picks the Q4_0 weights on an OpenCL phone', () => {
    const selection = selectModel(PHONE.E(), catalog);
    expect(selection.shape.backend).toBe('opencl');
    expect(selection.files[0].path).toBe('Qwen3.5-9B-Q4_0.gguf');
  });
});

describe('upgrade and downgrade rules', () => {
  it('offers Gemma 4 E2B on class B, text only, without making it default', () => {
    const selection = selectModel(PHONE.B(), catalog);
    expect(selection.model.id).toBe('lfm3-1.7b');
    expect(selection.upgradeOffer?.model.id).toBe('gemma-4-e2b-qat');
    expect(selection.upgradeOffer?.shape).toMatchObject({
      vision: false,
      contextSize: 8192,
    });
  });

  it('offers the 9B on class D only with 7 GB really available', () => {
    expect(selectModel(PHONE.D(), catalog).upgradeOffer).toBeUndefined();
    const raised = selectModel(PHONE.DRaised(), catalog);
    expect(raised.model.id).toBe('gemma-4-e4b-qat');
    expect(raised.upgradeOffer?.model.id).toBe('qwen3.5-9b');
    expect(raised.upgradeOffer?.shape).toMatchObject({
      vision: true,
      contextSize: 16384,
    });
  });

  it('does not offer an upgrade on an assumed (floored) reading', () => {
    // Simulator: 0 available, so the floor is used and the 7 GB rule cannot pass.
    const floored = profile(ios(64, 0));
    expect(floored.budget.source).toBe('floor');
    expect(selectModel(floored, catalog).upgradeOffer).toBeUndefined();
  });

  it('does not offer an upgrade that would cost context or vision', () => {
    // 12 GB Android: the 9B only fits at a quarter of the class context.
    const s24u = profile(android(11.2, 4, 'SM8650'));
    expect(s24u.deviceClass).toBe('D');
    expect(selectModel(s24u, catalog).upgradeOffer).toBeUndefined();
  });

  it('makes an "auto" upgrade the default', () => {
    const auto: Catalog = {
      ...catalog,
      classes: catalog.classes.map(c =>
        c.id === 'B' ? {...c, upgrade: {...c.upgrade!, mode: 'auto'}} : c,
      ),
    };
    const selection = selectModel(PHONE.B(), auto);
    expect(selection.model.id).toBe('gemma-4-e2b-qat');
    expect(selection.reason).toBe('upgraded');
    expect(selection.upgradeOffer).toBeUndefined();
  });

  it('drops the offer once the upgrade was demoted or revoked', () => {
    const demoted = selectModel(PHONE.B(), catalog, {
      demoted: {'gemma-4-e2b-qat': 'too_slow'},
    });
    expect(demoted.upgradeOffer).toBeUndefined();
    const revoked = selectModel(PHONE.B(), {
      ...catalog,
      revoked: ['gemma-4-e2b-qat'],
    });
    expect(revoked.upgradeOffer).toBeUndefined();
  });

  it('steps down past a demoted default and says why', () => {
    const selection = selectModel(PHONE.D(), catalog, {
      demoted: {'gemma-4-e4b-qat': 'too_slow'},
    });
    expect(selection.model.id).toBe('gemma-4-e2b-qat');
    expect(selection.reason).toBe('stepped_down');
    expect(selection.skipped).toEqual([
      {modelId: 'gemma-4-e4b-qat', why: 'too_slow'},
    ]);
    // No upgrade is offered to a phone that just stepped down.
    expect(selection.upgradeOffer).toBeUndefined();
  });

  it('steps down past a revoked default', () => {
    const selection = selectModel(PHONE.C(), {
      ...catalog,
      revoked: ['gemma-4-e2b-qat'],
    });
    expect(selection.model.id).toBe('lfm3-1.7b');
    expect(selection.skipped).toEqual([
      {modelId: 'gemma-4-e2b-qat', why: 'revoked'},
    ]);
  });

  it('shrinks the context before giving up vision or the model', () => {
    // Class C needs 1.2 GB of working memory; make the model hungrier.
    const hungry: Catalog = {
      ...catalog,
      models: catalog.models.map(m =>
        m.id === 'gemma-4-e2b-qat'
          ? {...m, memory: {...m.memory, kvBytesPerToken: 150000}}
          : m,
      ),
    };
    const selection = selectModel(PHONE.C(), hungry);
    expect(selection.model.id).toBe('gemma-4-e2b-qat');
    expect(selection.shape).toMatchObject({contextSize: 4096, vision: true});
  });

  it('gives up vision before giving up the model', () => {
    const fatProjector: Catalog = {
      ...catalog,
      models: catalog.models.map(m =>
        m.id === 'gemma-4-e2b-qat'
          ? {...m, projector: {...m.projector!, sizeBytes: 3 * GB}}
          : m,
      ),
    };
    const selection = selectModel(PHONE.C(), fatProjector);
    expect(selection.model.id).toBe('gemma-4-e2b-qat');
    expect(selection.shape.vision).toBe(false);
    expect(selection.files).toHaveLength(1);
  });

  it('steps down a model when memory does not fit at any shape', () => {
    const bloated: Catalog = {
      ...catalog,
      models: catalog.models.map(m =>
        m.id === 'gemma-4-e2b-qat'
          ? {...m, files: [{...m.files[0], sizeBytes: 6 * GB}]}
          : m,
      ),
    };
    const selection = selectModel(PHONE.C(), bloated);
    expect(selection.model.id).toBe('lfm3-1.7b');
    expect(selection.skipped).toEqual([
      {modelId: 'gemma-4-e2b-qat', why: 'memory'},
    ]);
  });

  it('always returns a model: last resort when nothing fits', () => {
    const starved = profile(ios(3.75, 0.2, 'iPhone14,6'));
    const selection = selectModel(starved, catalog);
    expect(selection.reason).toBe('last_resort');
    expect(selection.model.id).toBe('lfm3-1.7b');
    expect(selection.shape).toMatchObject({contextSize: 2048, vision: false});
    expect(selection.fit.fits).toBe(false);
    expect(selection.skipped).toEqual([]);
  });

  it('still returns a model when every ladder model is demoted', () => {
    const selection = selectModel(PHONE.A(), catalog, {
      demoted: {'lfm3-1.7b': 'crashed'},
    });
    expect(selection.reason).toBe('last_resort');
    expect(selection.model.id).toBe('lfm3-1.7b');
  });

  it('falls to the ladder end even if every model is revoked', () => {
    const selection = selectModel(PHONE.A(), {
      ...catalog,
      revoked: [...catalog.ladder],
    });
    expect(selection.reason).toBe('last_resort');
    expect(selection.model.id).toBe('lfm3-1.7b');
  });
});

describe('stepDown', () => {
  it('walks the standard ladder', () => {
    expect(stepDown(catalog, 'qwen3.5-9b')).toBe('gemma-4-e4b-qat');
    expect(stepDown(catalog, 'gemma-4-e4b-qat')).toBe('gemma-4-e2b-qat');
    expect(stepDown(catalog, 'gemma-4-e2b-qat')).toBe('lfm3-1.7b');
    expect(stepDown(catalog, 'lfm3-1.7b')).toBeNull();
  });

  it('walks the unrestricted ladder', () => {
    expect(stepDown(catalog, 'gemma-4-e4b-unrestricted')).toBe(
      'qwen3.5-4b-unrestricted',
    );
    expect(stepDown(catalog, 'qwen3.5-4b-unrestricted')).toBeNull();
  });

  it('sends an off-ladder model to the next smaller ladder model', () => {
    // Its Q4_0 file is smaller than Gemma 4 E2B, so the next smaller is LFM3.
    expect(stepDown(catalog, 'qwen3.5-4b')).toBe('lfm3-1.7b');
    expect(stepDown(catalog, 'qwen3.5-2b')).toBe('lfm3-1.7b');
    expect(stepDown(catalog, 'ghost')).toBeNull();
  });
});

describe('unrestricted add-on per class', () => {
  it.each([
    ['A', PHONE.A, undefined],
    ['B', PHONE.B, undefined],
    ['C', PHONE.C, 'qwen3.5-4b-unrestricted'],
    ['D', PHONE.D, 'gemma-4-e4b-unrestricted'],
    ['E', PHONE.E, 'gemma-4-e4b-unrestricted'],
  ] as const)('class %s', (_cls, phone, id) => {
    expect(selectUnrestricted(phone(), catalog)?.model.id).toBe(id);
  });

  it('steps down when the class pick does not fit', () => {
    // Class D by the numbers, but too little available for the E4B add-on.
    const tight: Catalog = {
      ...catalog,
      models: catalog.models.map(m =>
        m.id === 'gemma-4-e4b-unrestricted'
          ? {...m, files: [{...m.files[0], sizeBytes: 9 * GB}]}
          : m,
      ),
    };
    expect(selectUnrestricted(PHONE.D(), tight)?.model.id).toBe(
      'qwen3.5-4b-unrestricted',
    );
  });

  it('is null when nothing fits: the add-on is optional', () => {
    const starved = profile(ios(3.75, 0.2, 'iPhone14,6'));
    expect(selectUnrestricted(starved, catalog)).toBeNull();
  });

  it('respects demotions', () => {
    const choice = selectUnrestricted(PHONE.C(), catalog, {
      demoted: {'qwen3.5-4b-unrestricted': 'too_slow'},
    });
    expect(choice).toBeNull();
  });
});

describe('shapes', () => {
  it('halves the context down to the preferred floor', () => {
    expect(contextCandidates(16384, 4096)).toEqual([16384, 8192, 4096]);
    expect(contextCandidates(4096, 4096)).toEqual([4096]);
    expect(contextCandidates(2048, 4096)).toEqual([2048]);
  });

  it('never exceeds what the model supports', () => {
    const short: CatalogModel = {
      ...model('lfm3-1.7b'),
      context: {trained: 4096, default: 4096, max: 4096},
    };
    expect(
      bestShapeFor(short, PHONE.D(), catalog, true)?.shape.contextSize,
    ).toBe(4096);
  });

  it('in strict mode accepts no smaller context and no loss of vision', () => {
    const nineB = model('qwen3.5-9b');
    expect(bestShapeFor(nineB, PHONE.D(), catalog, true, true)).toBeNull();
    expect(
      bestShapeFor(nineB, PHONE.DRaised(), catalog, true, true)?.shape,
    ).toMatchObject({contextSize: 16384, vision: true});
  });
});
