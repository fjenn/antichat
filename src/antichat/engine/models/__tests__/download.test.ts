import {bundledCatalog} from '../catalog/bundledCatalog';
import {
  decideDownload,
  DownloadEnvironment,
  estimateDownloadSeconds,
  planFirstRun,
  requiredFreeBytes,
} from '../policy/download';
import {selectModel} from '../policy/select';

import {GB, MB, PHONE} from './fixtures/devices';

const catalog = bundledCatalog;
const policy = catalog.policy;
const wifi = {online: true, metered: false};
const cellular = {online: true, metered: true};
const offline = {online: false, metered: false};

const env = (over: Partial<DownloadEnvironment> = {}): DownloadEnvironment => ({
  network: wifi,
  freeStorageBytes: 64 * GB,
  ...over,
});

const filesC = selectModel(PHONE.C(), catalog).files;
const bytesC = 2620370976 + 985654080;

describe('storage and network checks', () => {
  it('starts on Wi-Fi with space', () => {
    expect(decideDownload(filesC, env(), policy)).toEqual({
      kind: 'start',
      files: filesC,
      bytes: bytesC,
    });
  });

  it('asks before using cellular data, once', () => {
    expect(decideDownload(filesC, env({network: cellular}), policy)).toEqual({
      kind: 'confirm_metered',
      files: filesC,
      bytes: bytesC,
    });
    expect(
      decideDownload(
        filesC,
        env({network: cellular, allowMetered: true}),
        policy,
      ).kind,
    ).toBe('start');
  });

  it('blocks when offline', () => {
    expect(decideDownload(filesC, env({network: offline}), policy)).toEqual({
      kind: 'blocked',
      reason: 'offline',
      bytes: bytesC,
    });
  });

  it('needs the download plus a margin of free space', () => {
    // 10% of 3.6 GB is less than the 500 MB minimum margin.
    expect(requiredFreeBytes(bytesC, policy)).toBe(bytesC + 500 * MB);
    expect(requiredFreeBytes(10 * GB, policy)).toBe(11 * GB);

    const short = decideDownload(
      filesC,
      env({freeStorageBytes: bytesC + 100 * MB}),
      policy,
    );
    expect(short).toEqual({
      kind: 'blocked',
      reason: 'storage',
      bytes: bytesC,
      neededBytes: bytesC + 500 * MB,
      freeBytes: bytesC + 100 * MB,
    });
  });

  it('reports storage before the network', () => {
    const decision = decideDownload(
      filesC,
      env({freeStorageBytes: 1 * GB, network: offline}),
      policy,
    );
    expect(decision).toMatchObject({kind: 'blocked', reason: 'storage'});
  });

  it('does not block when free space is unknown', () => {
    expect(
      decideDownload(filesC, env({freeStorageBytes: null}), policy).kind,
    ).toBe('start');
  });

  it('counts only what is missing', () => {
    const [weights, projector] = filesC;
    const half = Math.floor(projector.sizeBytes / 2);
    const decision = decideDownload(
      filesC,
      env({
        bytesOnDisk: file => (file === weights ? weights.sizeBytes : half),
        // Enough for the remaining half only.
        freeStorageBytes: projector.sizeBytes - half + 600 * MB,
      }),
      policy,
    );
    expect(decision).toEqual({
      kind: 'start',
      files: [projector],
      bytes: projector.sizeBytes - half,
    });
  });

  it('has nothing to do when everything is on disk, even offline', () => {
    expect(
      decideDownload(
        filesC,
        env({network: offline, bytesOnDisk: f => f.sizeBytes + 10}),
        policy,
      ),
    ).toEqual({kind: 'installed'});
  });
});

describe('first-run plan', () => {
  it('plans the class default when it fits on disk', () => {
    const plan = planFirstRun(PHONE.D(), catalog, env());
    expect(plan.selection.model.id).toBe('gemma-4-e4b-qat');
    expect(plan.decision.kind).toBe('start');
    expect(plan.storageLimited).toBeUndefined();
  });

  it('plans a smaller model when the disk is nearly full', () => {
    // Room for LFM3 (1.1 GB + margin) but not for Gemma 4 E4B or E2B.
    const plan = planFirstRun(
      PHONE.D(),
      catalog,
      env({freeStorageBytes: 2 * GB}),
    );
    expect(plan.selection.model.id).toBe('lfm3-1.7b');
    expect(plan.selection.reason).toBe('stepped_down');
    expect(plan.selection.skipped).toEqual([
      {modelId: 'gemma-4-e4b-qat', why: 'storage'},
      {modelId: 'gemma-4-e2b-qat', why: 'storage'},
    ]);
    expect(plan.decision.kind).toBe('start');
    expect(plan.storageLimited).toMatchObject({
      freeBytes: 2 * GB,
      wanted: {model: {id: 'gemma-4-e4b-qat'}},
    });
    expect(plan.storageLimited!.neededBytes).toBeGreaterThan(5 * GB);
  });

  it('reports the block for the proper model when nothing fits on disk', () => {
    const plan = planFirstRun(
      PHONE.D(),
      catalog,
      env({freeStorageBytes: 100 * MB}),
    );
    expect(plan.selection.model.id).toBe('gemma-4-e4b-qat');
    expect(plan.decision).toMatchObject({kind: 'blocked', reason: 'storage'});
    expect(plan.storageLimited).toBeUndefined();
  });

  it('keeps earlier demotions while looking for a model that fits', () => {
    const plan = planFirstRun(
      PHONE.D(),
      catalog,
      env({freeStorageBytes: 4.5 * GB}),
      {demoted: {'gemma-4-e2b-qat': 'too_slow'}},
    );
    expect(plan.selection.model.id).toBe('lfm3-1.7b');
  });

  it('passes network decisions through', () => {
    expect(
      planFirstRun(PHONE.A(), catalog, env({network: cellular})).decision.kind,
    ).toBe('confirm_metered');
    expect(
      planFirstRun(PHONE.A(), catalog, env({network: offline})).decision,
    ).toMatchObject({kind: 'blocked', reason: 'offline'});
  });
});

describe('download time estimate', () => {
  it('rounds up, and is unknown without a speed', () => {
    expect(estimateDownloadSeconds(2620370976, 12.5 * 1000 * 1000)).toBe(210);
    expect(estimateDownloadSeconds(1000, 0)).toBeNull();
  });
});
