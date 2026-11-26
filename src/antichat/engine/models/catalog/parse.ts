import {
  Backend,
  Catalog,
  CatalogClass,
  CatalogEmbedding,
  CatalogFile,
  CatalogModel,
  CatalogPolicy,
  CATALOG_SCHEMA_VERSION,
  DEVICE_CLASSES,
  DeviceClass,
  ModelLanguages,
  ProjectorFile,
  WeightsFile,
} from './types';

/** Thrown when a catalogue document does not match the schema. */
export class CatalogError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'CatalogError';
  }
}

type Json = Record<string, unknown>;

const fail = (path: string, expected: string): never => {
  throw new CatalogError(`${path}: expected ${expected}`);
};

const obj = (v: unknown, path: string): Json =>
  v !== null && typeof v === 'object' && !Array.isArray(v)
    ? (v as Json)
    : fail(path, 'an object');

const arr = (v: unknown, path: string): unknown[] =>
  Array.isArray(v) ? v : fail(path, 'an array');

const str = (v: unknown, path: string): string =>
  typeof v === 'string' && v.length > 0 ? v : fail(path, 'a non-empty string');

const bool = (v: unknown, path: string): boolean =>
  typeof v === 'boolean' ? v : fail(path, 'a boolean');

const num = (v: unknown, path: string, min = 0): number =>
  typeof v === 'number' && Number.isFinite(v) && v >= min
    ? v
    : fail(path, `a number >= ${min}`);

const int = (v: unknown, path: string, min = 0): number =>
  Number.isInteger(v) ? num(v, path, min) : fail(path, 'an integer');

const numOrNull = (v: unknown, path: string): number | null =>
  v === null ? null : num(v, path);

const oneOf = <T extends string>(
  v: unknown,
  allowed: readonly T[],
  path: string,
): T => (allowed.includes(v as T) ? (v as T) : fail(path, allowed.join(' | ')));

const optStr = (v: unknown, path: string): string | undefined =>
  v === undefined ? undefined : str(v, path);

const BACKENDS: readonly Backend[] = ['metal', 'opencl', 'cpu'];
const SHA256 = /^[0-9a-f]{64}$/;
const REPO = /^[\w.-]+\/[\w.-]+$/;
const REVISION = /^[0-9a-f]{40}$/;

function parseFile(v: unknown, path: string): CatalogFile {
  const o = obj(v, path);
  const repo = str(o.repo, `${path}.repo`);
  if (!REPO.test(repo)) {
    fail(`${path}.repo`, '"owner/name"');
  }
  const filePath = str(o.path, `${path}.path`);
  if (filePath.startsWith('/') || filePath.split('/').includes('..')) {
    fail(`${path}.path`, 'a relative path inside the repository');
  }
  const revision = str(o.revision, `${path}.revision`);
  if (!REVISION.test(revision)) {
    fail(`${path}.revision`, 'a 40-character commit id');
  }
  const sha256 = str(o.sha256, `${path}.sha256`);
  if (!SHA256.test(sha256)) {
    fail(`${path}.sha256`, 'a lower-case hex SHA-256');
  }
  return {
    repo,
    path: filePath,
    revision,
    sizeBytes: int(o.sizeBytes, `${path}.sizeBytes`, 1),
    sha256,
    quant: str(o.quant, `${path}.quant`),
  };
}

function parseWeights(v: unknown, path: string): WeightsFile {
  const file: WeightsFile = parseFile(v, path);
  const backends = obj(v, path).backends;
  if (backends !== undefined) {
    file.backends = arr(backends, `${path}.backends`).map((b, i) =>
      oneOf(b, BACKENDS, `${path}.backends[${i}]`),
    );
  }
  return file;
}

function parseProjector(v: unknown, path: string): ProjectorFile {
  const modalities = arr(obj(v, path).modalities, `${path}.modalities`).map(
    (m, i) => oneOf(m, ['image', 'audio'] as const, `${path}.modalities[${i}]`),
  );
  return {...parseFile(v, path), modalities};
}

const LANGUAGE_CODE = /^[a-z]{2,3}$/;

function parseLanguages(v: unknown, path: string): ModelLanguages {
  const o = obj(v, path);
  const languages: ModelLanguages = {source: str(o.source, `${path}.source`)};
  if (o.codes !== undefined) {
    languages.codes = arr(o.codes, `${path}.codes`).map((c, i) =>
      typeof c === 'string' && LANGUAGE_CODE.test(c)
        ? c
        : fail(`${path}.codes[${i}]`, 'an ISO 639 code'),
    );
  }
  if (o.count !== undefined) {
    languages.count = int(o.count, `${path}.count`, 1);
  }
  if (o.atLeast !== undefined) {
    languages.atLeast = bool(o.atLeast, `${path}.atLeast`);
  }
  if (!languages.codes?.length && !languages.count) {
    fail(path, 'codes or a count');
  }
  return languages;
}

function parseModel(v: unknown, path: string): CatalogModel {
  const o = obj(v, path);
  const licence = obj(o.licence, `${path}.licence`);
  const context = obj(o.context, `${path}.context`);
  const template = obj(o.template, `${path}.template`);
  const thinking = obj(template.thinking, `${path}.template.thinking`);
  const caps = obj(o.capabilities, `${path}.capabilities`);
  const memory = obj(o.memory, `${path}.memory`);
  const minMeasured = obj(
    memory.minMeasuredAvailableBytes,
    `${path}.memory.minMeasuredAvailableBytes`,
  );
  const files = arr(o.files, `${path}.files`).map((f, i) =>
    parseWeights(f, `${path}.files[${i}]`),
  );
  if (files.length === 0) {
    fail(`${path}.files`, 'at least one file');
  }
  const model: CatalogModel = {
    id: str(o.id, `${path}.id`),
    displayName: str(o.displayName, `${path}.displayName`),
    family: str(o.family, `${path}.family`),
    params: str(o.params, `${path}.params`),
    licence: {
      id: str(licence.id, `${path}.licence.id`),
      name: str(licence.name, `${path}.licence.name`),
      url: str(licence.url, `${path}.licence.url`),
      openSource: bool(licence.openSource, `${path}.licence.openSource`),
      notice: optStr(licence.notice, `${path}.licence.notice`),
    },
    tier: oneOf(o.tier, DEVICE_CLASSES, `${path}.tier`),
    role: oneOf(
      o.role,
      ['default', 'fallback', 'alternative'] as const,
      `${path}.role`,
    ),
    unrestricted: bool(o.unrestricted, `${path}.unrestricted`),
    files,
    context: {
      trained: int(context.trained, `${path}.context.trained`, 1),
      default: int(context.default, `${path}.context.default`, 1),
      max: int(context.max, `${path}.context.max`, 1),
    },
    template: {
      jinja: bool(template.jinja, `${path}.template.jinja`),
      toolFormat: str(template.toolFormat, `${path}.template.toolFormat`),
      thinking: {
        supported: bool(thinking.supported, `${path}.template.thinking`),
        default: bool(thinking.default, `${path}.template.thinking`),
        canDisable: bool(thinking.canDisable, `${path}.template.thinking`),
      },
    },
    capabilities: {
      tools: bool(caps.tools, `${path}.capabilities.tools`),
      vision: bool(caps.vision, `${path}.capabilities.vision`),
      audio: bool(caps.audio, `${path}.capabilities.audio`),
      thinking: bool(caps.thinking, `${path}.capabilities.thinking`),
    },
    memory: {
      kvBytesPerToken: num(memory.kvBytesPerToken, `${path}.memory.kv`),
      fixedBytes: num(memory.fixedBytes, `${path}.memory.fixedBytes`),
      minMeasuredAvailableBytes: {
        ios: num(minMeasured.ios, `${path}.memory.minMeasured.ios`),
        android: num(minMeasured.android, `${path}.memory.minMeasured.android`),
      },
      basis: oneOf(
        memory.basis,
        ['device-measured', 'gguf-upper-bound', 'estimate'] as const,
        `${path}.memory.basis`,
      ),
      note: optStr(memory.note, `${path}.memory.note`),
    },
    baseModel: optStr(o.baseModel, `${path}.baseModel`),
    summary: optStr(o.summary, `${path}.summary`),
    heldBack:
      o.heldBack === undefined
        ? undefined
        : bool(o.heldBack, `${path}.heldBack`),
    note: optStr(o.note, `${path}.note`),
  };
  if (o.projector !== undefined) {
    model.projector = parseProjector(o.projector, `${path}.projector`);
  }
  if (o.languages !== undefined) {
    model.languages = parseLanguages(o.languages, `${path}.languages`);
  }
  if (o.eval !== undefined) {
    model.eval = obj(o.eval, `${path}.eval`);
  }
  if (model.capabilities.vision && !model.projector) {
    fail(`${path}.projector`, 'a projector for a vision model');
  }
  return model;
}

function parseEmbedding(v: unknown, path: string): CatalogEmbedding {
  const o = obj(v, path);
  const licence = obj(o.licence, `${path}.licence`);
  return {
    id: str(o.id, `${path}.id`),
    displayName: str(o.displayName, `${path}.displayName`),
    licence: {
      id: str(licence.id, `${path}.licence.id`),
      name: str(licence.name, `${path}.licence.name`),
      url: str(licence.url, `${path}.licence.url`),
      openSource: bool(licence.openSource, `${path}.licence.openSource`),
      notice: optStr(licence.notice, `${path}.licence.notice`),
    },
    file: parseFile(o.file, `${path}.file`),
    nativeDims: int(o.nativeDims, `${path}.nativeDims`, 1),
    dims: int(o.dims, `${path}.dims`, 1),
    contextSize: int(o.contextSize, `${path}.contextSize`, 1),
    ramBytes: int(o.ramBytes, `${path}.ramBytes`, 1),
  };
}

function parseClass(v: unknown, path: string): CatalogClass {
  const o = obj(v, path);
  const requires = obj(o.requires, `${path}.requires`);
  const ios = obj(requires.ios, `${path}.requires.ios`);
  const android = obj(requires.android, `${path}.requires.android`);
  const f = obj(o.features, `${path}.features`);
  const cls: CatalogClass = {
    id: oneOf(o.id, DEVICE_CLASSES, `${path}.id`),
    marketedRamGb: num(o.marketedRamGb, `${path}.marketedRamGb`),
    requires: {
      ios: {
        weightsPoolBytes: num(ios.weightsPoolBytes, `${path}.requires.ios`),
        dirtyPoolBytes: num(ios.dirtyPoolBytes, `${path}.requires.ios`),
      },
      android: {poolBytes: num(android.poolBytes, `${path}.requires.android`)},
    },
    defaultModel: str(o.defaultModel, `${path}.defaultModel`),
    contextSize: int(o.contextSize, `${path}.contextSize`, 1),
    unrestrictedModel:
      o.unrestrictedModel === null || o.unrestrictedModel === undefined
        ? null
        : str(o.unrestrictedModel, `${path}.unrestrictedModel`),
    features: {
      vision: bool(f.vision, `${path}.features.vision`),
      imageGeneration: bool(f.imageGeneration, `${path}.features.imageGen`),
      voiceMode: bool(f.voiceMode, `${path}.features.voiceMode`),
      embeddings: bool(f.embeddings, `${path}.features.embeddings`),
      research: bool(f.research, `${path}.features.research`),
      followUps: bool(f.followUps, `${path}.features.followUps`),
      renderHtml: bool(f.renderHtml, `${path}.features.renderHtml`),
      backgroundMemory: bool(f.backgroundMemory, `${path}.features.bgMemory`),
      searchQueriesPerTurn: int(
        f.searchQueriesPerTurn,
        `${path}.features.searchQueriesPerTurn`,
      ),
      maxTools: int(f.maxTools, `${path}.features.maxTools`),
    },
  };
  if (o.upgrade !== undefined) {
    const u = obj(o.upgrade, `${path}.upgrade`);
    cls.upgrade = {
      modelId: str(u.modelId, `${path}.upgrade.modelId`),
      mode: oneOf(u.mode, ['offer', 'auto'] as const, `${path}.upgrade.mode`),
    };
    if (u.minMeasuredAvailableBytes !== undefined) {
      const m = obj(u.minMeasuredAvailableBytes, `${path}.upgrade.min`);
      cls.upgrade.minMeasuredAvailableBytes = {
        ios: m.ios === undefined ? undefined : num(m.ios, `${path}.upgrade`),
        android:
          m.android === undefined
            ? undefined
            : num(m.android, `${path}.upgrade`),
      };
    }
  }
  return cls;
}

/** Steps must be ascending and end with the open-ended (null) step. */
function parseSteps<K extends string>(
  v: unknown,
  key: K,
  path: string,
): Array<{maxRamBytes: number | null} & Record<K, number>> {
  const steps = arr(v, path).map((s, i) => {
    const o = obj(s, `${path}[${i}]`);
    return {
      maxRamBytes: numOrNull(o.maxRamBytes, `${path}[${i}].maxRamBytes`),
      [key]: num(o[key], `${path}[${i}].${key}`),
    } as {maxRamBytes: number | null} & Record<K, number>;
  });
  if (steps.length === 0 || steps[steps.length - 1].maxRamBytes !== null) {
    fail(path, 'steps ending with maxRamBytes: null');
  }
  return steps;
}

function parsePolicy(v: unknown, path: string): CatalogPolicy {
  const o = obj(v, path);
  const storage = obj(o.storage, `${path}.storage`);
  const ios = obj(o.ios, `${path}.ios`);
  const android = obj(o.android, `${path}.android`);
  const cap = obj(o.tierCap, `${path}.tierCap`);
  const gpu = obj(o.gpu, `${path}.gpu`);
  const timeouts = obj(gpu.initTimeoutMs, `${path}.gpu.initTimeoutMs`);
  const noGpu = obj(gpu.noGpuMaxRamBytes, `${path}.gpu.noGpuMaxRamBytes`);
  const capOf = (tier: string): DeviceClass =>
    oneOf(cap[tier], DEVICE_CLASSES, `${path}.tierCap.${tier}`);
  return {
    speedFloorTokPerSec: num(o.speedFloorTokPerSec, `${path}.speedFloor`),
    calibrationSeconds: num(o.calibrationSeconds, `${path}.calibration`),
    minContextSize: int(o.minContextSize, `${path}.minContextSize`, 256),
    preferredMinContextSize: int(
      o.preferredMinContextSize,
      `${path}.preferredMinContextSize`,
      256,
    ),
    visionWorkingBytes: num(o.visionWorkingBytes, `${path}.visionWorking`),
    storage: {
      marginBytes: num(storage.marginBytes, `${path}.storage.marginBytes`),
      marginFraction: num(storage.marginFraction, `${path}.storage.fraction`),
    },
    ios: {
      weightsFractionOfRam: num(ios.weightsFractionOfRam, `${path}.ios`),
      dirtyFractionOfAvailable: num(
        ios.dirtyFractionOfAvailable,
        `${path}.ios`,
      ),
      availableFloor: parseSteps(
        ios.availableFloor,
        'bytes',
        `${path}.ios.availableFloor`,
      ),
    },
    android: {
      overheadFactor: num(android.overheadFactor, `${path}.android`, 1),
      reserveBytes: num(android.reserveBytes, `${path}.android.reserveBytes`),
      budgetFractions: parseSteps(
        android.budgetFractions,
        'fraction',
        `${path}.android.budgetFractions`,
      ),
    },
    tierCap: {
      low: capOf('low'),
      mid: capOf('mid'),
      high: capOf('high'),
      flagship: capOf('flagship'),
    },
    gpu: {
      iosMinMajor: int(gpu.iosMinMajor, `${path}.gpu.iosMinMajor`),
      iosMetalReserveBytes: num(gpu.iosMetalReserveBytes, `${path}.gpu`),
      adrenoMinGeneration: int(gpu.adrenoMinGeneration, `${path}.gpu`),
      noGpuMaxRamBytes: {
        ios: num(noGpu.ios, `${path}.gpu.noGpuMaxRamBytes.ios`),
        android: num(noGpu.android, `${path}.gpu.noGpuMaxRamBytes.android`),
      },
      androidLayerCaps: parseSteps(
        gpu.androidLayerCaps,
        'layers',
        `${path}.gpu.androidLayerCaps`,
      ),
      initTimeoutMs: {
        ios: num(timeouts.ios, `${path}.gpu.initTimeoutMs.ios`),
        android: num(timeouts.android, `${path}.gpu.initTimeoutMs.android`),
      },
    },
  };
}

/**
 * Validate a catalogue document and return it typed. Throws `CatalogError`
 * with the path of the first problem. Unknown fields are dropped, so a newer
 * minor revision of the schema still loads.
 */
export function parseCatalog(input: unknown): Catalog {
  const o = obj(input, 'catalog');
  const schemaVersion = int(o.schemaVersion, 'schemaVersion', 1);
  if (schemaVersion !== CATALOG_SCHEMA_VERSION) {
    throw new CatalogError(
      `schemaVersion ${schemaVersion} is not supported (this app reads ${CATALOG_SCHEMA_VERSION})`,
    );
  }
  const models = arr(o.models, 'models').map((m, i) =>
    parseModel(m, `models[${i}]`),
  );
  const classes = arr(o.classes, 'classes').map((c, i) =>
    parseClass(c, `classes[${i}]`),
  );
  const strings = (v: unknown, path: string) =>
    arr(v, path).map((s, i) => str(s, `${path}[${i}]`));
  const catalog: Catalog = {
    schemaVersion,
    serial: int(o.serial, 'serial', 1),
    issuedAt: str(o.issuedAt, 'issuedAt'),
    expiresAt: o.expiresAt === null ? null : str(o.expiresAt, 'expiresAt'),
    minAppVersion: str(o.minAppVersion, 'minAppVersion'),
    sources: optStr(o.sources, 'sources'),
    policy: parsePolicy(o.policy, 'policy'),
    ladder: strings(o.ladder, 'ladder'),
    unrestrictedLadder: strings(o.unrestrictedLadder, 'unrestrictedLadder'),
    classes,
    models,
    revoked: strings(o.revoked ?? [], 'revoked'),
  };
  if (o.embedding !== undefined && o.embedding !== null) {
    catalog.embedding = parseEmbedding(o.embedding, 'embedding');
  }
  checkReferences(catalog);
  return catalog;
}

/** Cross-field rules: every id resolves, ladders are well formed. */
function checkReferences(catalog: Catalog): void {
  const byId = new Map<string, CatalogModel>();
  for (const model of catalog.models) {
    if (byId.has(model.id)) {
      throw new CatalogError(`models: duplicate id "${model.id}"`);
    }
    byId.set(model.id, model);
  }
  const need = (id: string, path: string, unrestricted: boolean) => {
    const model = byId.get(id);
    if (!model) {
      throw new CatalogError(`${path}: unknown model "${id}"`);
    }
    if (model.unrestricted !== unrestricted) {
      throw new CatalogError(
        `${path}: "${id}" must ${unrestricted ? '' : 'not '}be unrestricted`,
      );
    }
  };
  if (catalog.ladder.length === 0) {
    throw new CatalogError('ladder: expected at least one model');
  }
  catalog.ladder.forEach((id, i) => need(id, `ladder[${i}]`, false));
  catalog.unrestrictedLadder.forEach((id, i) =>
    need(id, `unrestrictedLadder[${i}]`, true),
  );
  const ids = catalog.classes.map(c => c.id);
  if (ids.join() !== DEVICE_CLASSES.join()) {
    throw new CatalogError(
      `classes: expected exactly ${DEVICE_CLASSES.join(', ')} in order`,
    );
  }
  for (const cls of catalog.classes) {
    const path = `classes.${cls.id}`;
    need(cls.defaultModel, `${path}.defaultModel`, false);
    if (!catalog.ladder.includes(cls.defaultModel)) {
      throw new CatalogError(`${path}.defaultModel: must be on the ladder`);
    }
    if (cls.unrestrictedModel !== null) {
      need(cls.unrestrictedModel, `${path}.unrestrictedModel`, true);
      if (!catalog.unrestrictedLadder.includes(cls.unrestrictedModel)) {
        throw new CatalogError(
          `${path}.unrestrictedModel: must be on the unrestricted ladder`,
        );
      }
    }
    if (cls.upgrade) {
      need(cls.upgrade.modelId, `${path}.upgrade.modelId`, false);
    }
  }
  for (const model of catalog.models) {
    if (model.baseModel !== undefined && !byId.has(model.baseModel)) {
      throw new CatalogError(
        `models.${model.id}.baseModel: unknown model "${model.baseModel}"`,
      );
    }
  }
}
