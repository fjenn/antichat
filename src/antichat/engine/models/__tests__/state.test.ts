import {
  canApply,
  isInstalled,
  LoadedInfo,
  makeProgress,
  ModelEvent,
  ModelState,
  NOT_INSTALLED,
  READY,
  transition,
} from '../state';

const info: LoadedInfo = {
  backend: 'metal',
  gpuLayers: 99,
  contextSize: 8192,
  vision: true,
  attempt: 'gpu',
  degraded: false,
};

const run = (events: ModelEvent[], from: ModelState = NOT_INSTALLED) =>
  events.reduce(transition, from);

const downloading = run([{type: 'DOWNLOAD_STARTED', totalBytes: 1000}]);
const verifying = run([{type: 'DOWNLOAD_COMPLETED'}], downloading);
const loading = run([{type: 'LOAD_STARTED'}], READY);
const loaded = run([{type: 'LOAD_SUCCEEDED', info}], loading);

describe('model state machine', () => {
  it('walks the happy path', () => {
    const states = [
      {type: 'DOWNLOAD_STARTED', totalBytes: 1000},
      {type: 'DOWNLOAD_PROGRESS', receivedBytes: 500, bytesPerSecond: 100},
      {type: 'DOWNLOAD_COMPLETED'},
      {type: 'VERIFY_PROGRESS', fraction: 0.5},
      {type: 'VERIFY_PASSED'},
      {type: 'LOAD_STARTED'},
      {type: 'LOAD_ATTEMPT', index: 0, total: 4, kind: 'gpu'},
      {type: 'LOAD_SUCCEEDED', info},
    ] as ModelEvent[];
    const seen: string[] = [];
    states.reduce((state, event) => {
      const next = transition(state, event);
      seen.push(next.status);
      return next;
    }, NOT_INSTALLED);
    expect(seen).toEqual([
      'downloading',
      'downloading',
      'verifying',
      'verifying',
      'ready',
      'loading',
      'loading',
      'loaded',
    ]);
  });

  it('carries progress with speed and time left', () => {
    const state = run(
      [{type: 'DOWNLOAD_PROGRESS', receivedBytes: 250, bytesPerSecond: 50}],
      downloading,
    );
    expect(state).toEqual({
      status: 'downloading',
      paused: false,
      progress: {
        receivedBytes: 250,
        totalBytes: 1000,
        fraction: 0.25,
        bytesPerSecond: 50,
        etaSeconds: 15,
      },
    });
  });

  it('starts from bytes already on disk when resuming', () => {
    const state = transition(NOT_INSTALLED, {
      type: 'DOWNLOAD_STARTED',
      totalBytes: 1000,
      receivedBytes: 400,
    });
    expect(state).toMatchObject({progress: {fraction: 0.4}});
  });

  it('never lets progress run backwards or past the total', () => {
    const half = run(
      [{type: 'DOWNLOAD_PROGRESS', receivedBytes: 500}],
      downloading,
    );
    expect(
      transition(half, {type: 'DOWNLOAD_PROGRESS', receivedBytes: 100}),
    ).toBe(half);
    const over = transition(half, {
      type: 'DOWNLOAD_PROGRESS',
      receivedBytes: 5000,
    });
    expect(over).toMatchObject({progress: {receivedBytes: 1000, fraction: 1}});
  });

  it('pauses with a reason and resumes', () => {
    const paused = transition(downloading, {
      type: 'DOWNLOAD_PAUSED',
      reason: 'offline',
    });
    expect(paused).toMatchObject({paused: true, pauseReason: 'offline'});
    // Pausing twice changes nothing; the first reason stays.
    expect(transition(paused, {type: 'DOWNLOAD_PAUSED', reason: 'user'})).toBe(
      paused,
    );
    const late = transition(paused, {
      type: 'DOWNLOAD_PROGRESS',
      receivedBytes: 10,
      bytesPerSecond: 99,
    });
    // A late progress callback updates bytes but not speed, and stays paused.
    expect(late).toMatchObject({paused: true});
    expect((late as any).progress.bytesPerSecond).toBeUndefined();

    const resumed = transition(paused, {type: 'DOWNLOAD_RESUMED'});
    expect(resumed).toMatchObject({status: 'downloading', paused: false});
    expect((resumed as any).pauseReason).toBeUndefined();
    expect(transition(downloading, {type: 'DOWNLOAD_RESUMED'})).toBe(
      downloading,
    );
  });

  it('cancels back to not installed', () => {
    expect(transition(downloading, {type: 'DOWNLOAD_CANCELLED'})).toBe(
      NOT_INSTALLED,
    );
    expect(transition(READY, {type: 'DOWNLOAD_CANCELLED'})).toBe(READY);
  });

  it('turns failures into typed states instead of alerts', () => {
    expect(
      transition(downloading, {
        type: 'DOWNLOAD_FAILED',
        reason: 'download_failed',
        detail: 'HTTP 503',
      }),
    ).toEqual({
      status: 'failed',
      reason: 'download_failed',
      stage: 'download',
      retryable: true,
      resumeTo: 'not_installed',
      detail: 'HTTP 503',
    });
    // Blocked before it started: no space.
    expect(
      transition(NOT_INSTALLED, {
        type: 'DOWNLOAD_FAILED',
        reason: 'storage_full',
      }),
    ).toMatchObject({reason: 'storage_full', retryable: false});
    expect(transition(verifying, {type: 'VERIFY_FAILED'})).toMatchObject({
      reason: 'checksum_mismatch',
      stage: 'verify',
      resumeTo: 'not_installed',
    });
    expect(
      transition(loading, {type: 'LOAD_FAILED', reason: 'out_of_memory'}),
    ).toMatchObject({
      reason: 'out_of_memory',
      stage: 'load',
      retryable: true,
      resumeTo: 'ready',
    });
    expect(
      transition(READY, {type: 'LOAD_FAILED', reason: 'file_missing'}),
    ).toMatchObject({retryable: false, resumeTo: 'not_installed'});
  });

  it('retries from where it failed', () => {
    const loadFailed = transition(loading, {
      type: 'LOAD_FAILED',
      reason: 'load_failed',
    });
    expect(transition(loadFailed, {type: 'RETRY'})).toBe(READY);
    const badHash = transition(verifying, {type: 'VERIFY_FAILED'});
    expect(transition(badHash, {type: 'RETRY'})).toBe(NOT_INSTALLED);
    expect(transition(READY, {type: 'RETRY'})).toBe(READY);
  });

  it('records the measured speed on a loaded model', () => {
    expect(
      transition(loaded, {type: 'SPEED_MEASURED', tokensPerSecond: 31.5}),
    ).toMatchObject({info: {tokensPerSecond: 31.5, gpuLayers: 99}});
    expect(
      transition(READY, {type: 'SPEED_MEASURED', tokensPerSecond: 1}),
    ).toBe(READY);
  });

  it('unloads to ready, also while still loading', () => {
    expect(transition(loaded, {type: 'UNLOADED'})).toBe(READY);
    expect(transition(loading, {type: 'UNLOADED'})).toBe(READY);
    expect(transition(NOT_INSTALLED, {type: 'UNLOADED'})).toBe(NOT_INSTALLED);
  });

  it('removes from any settled state, but not mid-download', () => {
    expect(transition(READY, {type: 'REMOVED'})).toBe(NOT_INSTALLED);
    expect(transition(loaded, {type: 'REMOVED'})).toBe(NOT_INSTALLED);
    expect(transition(downloading, {type: 'REMOVED'})).toBe(downloading);
  });

  it('finds a model already on disk at start-up', () => {
    expect(transition(NOT_INSTALLED, {type: 'FOUND_ON_DISK'})).toBe(READY);
    expect(transition(loaded, {type: 'FOUND_ON_DISK'})).toBe(loaded);
  });

  it('ignores every event that does not belong to the current state', () => {
    const outOfPlace: Array<[ModelState, ModelEvent]> = [
      [READY, {type: 'DOWNLOAD_STARTED', totalBytes: 1}],
      [NOT_INSTALLED, {type: 'DOWNLOAD_PROGRESS', receivedBytes: 1}],
      [NOT_INSTALLED, {type: 'DOWNLOAD_COMPLETED'}],
      [READY, {type: 'DOWNLOAD_PAUSED', reason: 'user'}],
      [loaded, {type: 'DOWNLOAD_FAILED', reason: 'offline'}],
      [downloading, {type: 'VERIFY_PASSED'}],
      [downloading, {type: 'VERIFY_PROGRESS', fraction: 0.2}],
      [READY, {type: 'VERIFY_FAILED'}],
      [NOT_INSTALLED, {type: 'LOAD_STARTED'}],
      [READY, {type: 'LOAD_ATTEMPT', index: 0, total: 1, kind: 'cpu'}],
      [READY, {type: 'LOAD_SUCCEEDED', info}],
      [loaded, {type: 'LOAD_FAILED', reason: 'load_failed'}],
    ];
    for (const [state, event] of outOfPlace) {
      expect(transition(state, event)).toBe(state);
      expect(canApply(state, event)).toBe(false);
    }
    expect(canApply(READY, {type: 'LOAD_STARTED'})).toBe(true);
  });

  it('clamps verification progress', () => {
    expect(
      transition(verifying, {type: 'VERIFY_PROGRESS', fraction: 7}),
    ).toEqual({status: 'verifying', fraction: 1});
    expect(
      transition(verifying, {type: 'VERIFY_PROGRESS', fraction: NaN}),
    ).toEqual({status: 'verifying', fraction: 0});
  });
});

describe('helpers', () => {
  it('knows when a model is on disk', () => {
    expect(isInstalled(NOT_INSTALLED)).toBe(false);
    expect(isInstalled(downloading)).toBe(false);
    expect(isInstalled(verifying)).toBe(false);
    expect(isInstalled(READY)).toBe(true);
    expect(isInstalled(loading)).toBe(true);
    expect(isInstalled(loaded)).toBe(true);
    expect(
      isInstalled(
        transition(loading, {type: 'LOAD_FAILED', reason: 'load_failed'}),
      ),
    ).toBe(true);
    expect(isInstalled(transition(verifying, {type: 'VERIFY_FAILED'}))).toBe(
      false,
    );
  });

  it('builds progress safely', () => {
    expect(makeProgress(0, 0)).toEqual({
      receivedBytes: 0,
      totalBytes: 0,
      fraction: 0,
    });
    expect(makeProgress(-5, 100).receivedBytes).toBe(0);
    expect(makeProgress(50, 100, 0).etaSeconds).toBeUndefined();
  });
});
