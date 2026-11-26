import {bundledCatalog} from '../catalog/bundledCatalog';
import {getModel} from '../catalog/lookup';
import type {CatalogModel} from '../catalog/types';
import {
  InitAttempt,
  InitChainError,
  LoadJournal,
  planInitAttempts,
  reducedGpuLayers,
  runInitChain,
} from '../policy/initChain';
import {MemoryStorage} from '../storage';

import {android, GB, ios, PHONE, profile} from './fixtures/devices';

const policy = bundledCatalog.policy;
const e4b = getModel(bundledCatalog, 'gemma-4-e4b-qat') as CatalogModel;
const shape = {contextSize: 16384, vision: true, backend: 'metal' as const};
const kinds = (attempts: InitAttempt[]) => attempts.map(a => a.kind);

describe('init plan', () => {
  it('goes GPU -> fewer layers -> CPU -> CPU at the smallest context', () => {
    const attempts = planInitAttempts(PHONE.D(), e4b, shape, policy);
    expect(kinds(attempts)).toEqual([
      'gpu',
      'gpu_reduced',
      'cpu',
      'cpu_min_context',
    ]);
    expect(attempts[0]).toMatchObject({
      backend: 'metal',
      gpuLayers: 99,
      contextSize: 16384,
      vision: true,
      timeoutMs: 45000,
    });
    expect(attempts[1].gpuLayers).toBeLessThan(attempts[0].gpuLayers);
    expect(attempts[1].gpuLayers).toBeGreaterThan(0);
    expect(attempts[2]).toMatchObject({
      backend: 'cpu',
      gpuLayers: 0,
      contextSize: 16384,
      timeoutMs: null,
    });
    expect(attempts[3]).toMatchObject({
      contextSize: 2048,
      vision: false,
      gpuLayers: 0,
    });
  });

  it('starts on the CPU where there is no usable GPU', () => {
    const simulator = profile(ios(11.45, 0, 'iPhone18,1', {isEmulator: true}));
    expect(kinds(planInitAttempts(simulator, e4b, shape, policy))).toEqual([
      'cpu',
      'cpu_min_context',
    ]);
  });

  it('has a single CPU attempt when already at the smallest shape', () => {
    const simulator = profile(ios(11.45, 0, 'iPhone18,1', {isEmulator: true}));
    const smallest = {
      contextSize: 2048,
      vision: false,
      backend: 'cpu' as const,
    };
    expect(kinds(planInitAttempts(simulator, e4b, smallest, policy))).toEqual([
      'cpu',
    ]);
  });

  it('uses the Adreno cap and the Android timeout', () => {
    const s25 = profile(android(11.2, 5));
    const attempts = planInitAttempts(
      s25,
      e4b,
      {...shape, backend: 'opencl'},
      policy,
    );
    expect(attempts[0]).toMatchObject({
      backend: 'opencl',
      gpuLayers: 24,
      timeoutMs: 25000,
    });
    expect(attempts[1]).toMatchObject({kind: 'gpu_reduced', gpuLayers: 12});
  });

  it('scales the reduced offload to free memory on iOS', () => {
    const device = PHONE.D();
    const size = e4b.files[0].sizeBytes;
    // Lots free: still a real step down (half).
    expect(reducedGpuLayers(device, size, policy, 12 * GB)).toBe(49);
    // 3.17 GB free minus the 1.6 GiB reserve covers about a third of 4.2 GB.
    const tight = reducedGpuLayers(device, size, policy, 3.17 * GB);
    expect(tight).toBeGreaterThan(20);
    expect(tight).toBeLessThan(40);
    // Nothing free beyond the reserve: no reduced attempt at all.
    expect(reducedGpuLayers(device, size, policy, 1 * GB)).toBe(0);
    expect(
      kinds(
        planInitAttempts(device, e4b, shape, policy, {availableBytes: 1 * GB}),
      ),
    ).toEqual(['gpu', 'cpu', 'cpu_min_context']);
    expect(reducedGpuLayers(device, 0, policy, 12 * GB)).toBe(0);
  });

  it('has no reduced step without a GPU', () => {
    const cpuOnly = profile(
      android(11.2, 5, 'Tensor G4', {gpuRenderer: 'Mali'}),
    );
    expect(reducedGpuLayers(cpuOnly, 1, policy, 12 * GB)).toBe(0);
  });

  it('skips attempts that crashed the app, and anything heavier', () => {
    const plan = (crashed: any[]) =>
      kinds(planInitAttempts(PHONE.D(), e4b, shape, policy, {crashed}));
    expect(plan(['gpu'])).toEqual(['gpu_reduced', 'cpu', 'cpu_min_context']);
    expect(plan(['gpu_reduced'])).toEqual(['cpu', 'cpu_min_context']);
    expect(plan(['gpu', 'cpu'])).toEqual(['cpu_min_context']);
    expect(plan(['cpu_min_context'])).toEqual([]);
  });
});

describe('running the chain', () => {
  const attempts = planInitAttempts(PHONE.D(), e4b, shape, policy);
  const release = jest.fn(async () => undefined);

  beforeEach(() => release.mockClear());

  it('returns the first context that initialises', async () => {
    const init = jest.fn(async (a: InitAttempt) => `ctx:${a.kind}`);
    const result = await runInitChain({attempts, init, release});
    expect(result.context).toBe('ctx:gpu');
    expect(result.failures).toEqual([]);
    expect(init).toHaveBeenCalledTimes(1);
  });

  it('falls through GPU failures to the CPU and reports each step', async () => {
    const seen: string[] = [];
    const init = jest.fn(async (a: InitAttempt) => {
      if (a.backend !== 'cpu') {
        throw new Error('Metal buffer allocation failed');
      }
      return 'cpu-context';
    });
    const result = await runInitChain({
      attempts,
      init,
      release,
      onAttempt: (a, index, total) =>
        seen.push(`${index + 1}/${total} ${a.kind}`),
    });
    expect(result.context).toBe('cpu-context');
    expect(result.attempt.kind).toBe('cpu');
    expect(result.failures.map(f => f.attempt.kind)).toEqual([
      'gpu',
      'gpu_reduced',
    ]);
    expect(seen).toEqual(['1/4 gpu', '2/4 gpu_reduced', '3/4 cpu']);
  });

  it('throws a typed error when every attempt fails', async () => {
    const init = async (a: InitAttempt) => {
      throw a.kind === 'cpu'
        ? 'failed to allocate 4096 MiB'
        : new Error('nope');
    };
    const error = await runInitChain({attempts, init, release}).catch(e => e);
    expect(error).toBeInstanceOf(InitChainError);
    expect(error.reason).toBe('out_of_memory');
    expect(error.failures).toHaveLength(4);
    expect(error.message).toContain('cpu: failed to allocate');
  });

  it('classifies other failures as load errors', async () => {
    const init = async () => {
      throw new Error('unknown model architecture');
    };
    const error = await runInitChain({attempts, init, release}).catch(e => e);
    expect(error.reason).toBe('load_error');
  });

  it('fails cleanly when no attempt is left', async () => {
    const error = await runInitChain({
      attempts: [],
      init: async () => 'x',
      release,
    }).catch(e => e);
    expect(error.reason).toBe('no_attempts');
    expect(error.message).toMatch(/no init attempt/);
  });

  describe('with a hung GPU driver', () => {
    beforeEach(() => jest.useFakeTimers());
    afterEach(() => jest.useRealTimers());

    it('times out, moves on, and frees the context that arrives late', async () => {
      let finishGpu: (context: string) => void = () => undefined;
      const init = jest.fn((a: InitAttempt) =>
        a.kind === 'gpu'
          ? new Promise<string>(resolve => {
              finishGpu = resolve;
            })
          : Promise.resolve(`ctx:${a.kind}`),
      );
      const running = runInitChain({attempts, init, release});
      await jest.advanceTimersByTimeAsync(45000);
      const result = await running;
      expect(result.context).toBe('ctx:gpu_reduced');
      expect(result.failures[0]).toMatchObject({timedOut: true});
      expect(result.failures[0].message).toMatch(/timed out after 45000 ms/);

      expect(release).not.toHaveBeenCalled();
      finishGpu('late-gpu-context');
      await jest.advanceTimersByTimeAsync(0);
      expect(release).toHaveBeenCalledWith('late-gpu-context');
    });

    it('does not put a timeout on CPU attempts', async () => {
      const cpuOnly = attempts.filter(a => a.kind === 'cpu');
      let finish: (context: string) => void = () => undefined;
      const running = runInitChain({
        attempts: cpuOnly,
        init: () =>
          new Promise<string>(resolve => {
            finish = resolve;
          }),
        release,
      });
      await jest.advanceTimersByTimeAsync(10 * 60 * 1000);
      finish('slow-cpu');
      expect((await running).context).toBe('slow-cpu');
    });
  });
});

describe('load journal', () => {
  it('records an attempt that never finished as a crash', async () => {
    const storage = new MemoryStorage();
    const before = new LoadJournal(storage);
    await before.begin('gemma-4-e4b-qat', 'gpu');
    // ... the process is killed here ...

    const after = new LoadJournal(storage);
    expect(await after.recoverFromCrash()).toEqual({
      modelId: 'gemma-4-e4b-qat',
      kind: 'gpu',
    });
    expect(await after.crashedKinds('gemma-4-e4b-qat')).toEqual(['gpu']);
    expect(await after.crashedKinds('other')).toEqual([]);
    // Reported once.
    expect(await after.recoverFromCrash()).toBeNull();
  });

  it('accumulates crashes per model and can be reset', async () => {
    const journal = new LoadJournal(new MemoryStorage());
    for (const kind of ['gpu', 'gpu_reduced', 'gpu'] as const) {
      await journal.begin('m', kind);
      await journal.recoverFromCrash();
    }
    expect(await journal.crashedKinds('m')).toEqual(['gpu', 'gpu_reduced']);
    await journal.reset();
    expect(await journal.crashedKinds('m')).toEqual([]);
  });

  it('is clean after a load that finished, pass or fail', async () => {
    const storage = new MemoryStorage();
    const journal = new LoadJournal(storage);
    const attempts = planInitAttempts(PHONE.D(), e4b, shape, policy);
    await runInitChain({
      attempts,
      journal,
      modelId: 'm',
      init: async a => {
        if (a.kind === 'gpu') {
          throw new Error('no');
        }
        return 'ok';
      },
      release: async () => undefined,
    });
    expect(await journal.recoverFromCrash()).toBeNull();
    expect(await journal.crashedKinds('m')).toEqual([]);
  });

  it('leaves the pending mark while an attempt is running', async () => {
    const storage = new MemoryStorage();
    const journal = new LoadJournal(storage);
    let marked: string | null = null;
    await runInitChain({
      attempts: planInitAttempts(PHONE.D(), e4b, shape, policy),
      journal,
      modelId: 'm',
      init: async () => {
        marked = await storage.getItem('antichat.models.load.pending');
        return 'ok';
      },
      release: async () => undefined,
    });
    expect(JSON.parse(marked!)).toEqual({modelId: 'm', kind: 'gpu'});
  });

  it('never lets broken storage block a load', async () => {
    const broken = {
      getItem: async () => {
        throw new Error('disk');
      },
      setItem: async () => {
        throw new Error('disk');
      },
      removeItem: async () => {
        throw new Error('disk');
      },
    };
    const journal = new LoadJournal(broken);
    await expect(journal.begin('m', 'gpu')).resolves.toBeUndefined();
    await expect(journal.finish()).resolves.toBeUndefined();
    await expect(journal.reset()).resolves.toBeUndefined();
    expect(await journal.recoverFromCrash()).toBeNull();
    expect(await journal.crashedKinds('m')).toEqual([]);
  });
});
