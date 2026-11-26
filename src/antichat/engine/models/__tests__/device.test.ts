import {bundledCatalog} from '../catalog/bundledCatalog';
import {
  adrenoGeneration,
  classifyDevice,
  gpuHintFor,
  knownIssuesFor,
  lowerClass,
  memoryClassFor,
  osMajorOf,
  upstreamClassifiers,
  upstreamTierFor,
} from '../device/classify';
import {
  androidFloorBytes,
  computeMemoryBudget,
  stepValue,
} from '../device/memory';

import {android, GB, GiB, ios, MB, profile} from './fixtures/devices';

const policy = bundledCatalog.policy;

describe('memory budget: iOS', () => {
  it('uses the measured reading as it is', () => {
    const budget = computeMemoryBudget(ios(11.45, 3.17), policy);
    expect(budget.source).toBe('measured');
    expect(budget.shared).toBe(false);
    expect(budget.availableBytes).toBe(3.17 * GB);
    expect(budget.dirtyPoolBytes).toBeCloseTo(0.5 * 3.17 * GB);
    expect(budget.weightsPoolBytes).toBeCloseTo(0.55 * 11.45 * GiB);
  });

  it('does not raise a low reading: on iOS the limit is real', () => {
    // A 12 GB iPhone that reports 1 GB really has 1 GB before it is killed.
    const budget = computeMemoryBudget(ios(11.45, 1.0), policy);
    expect(budget.source).toBe('measured');
    expect(budget.dirtyPoolBytes).toBeCloseTo(0.5 * GB);
  });

  it.each([
    ['missing', undefined],
    ['zero (Simulator)', 0],
    ['NaN', NaN],
    ['negative', -5],
  ])('falls back to the per-RAM floor when the reading is %s', (_n, value) => {
    const snapshot = {...ios(11.45, 1), availableBytes: value as any};
    const budget = computeMemoryBudget(snapshot, policy);
    expect(budget.source).toBe('floor');
    expect(budget.availableBytes).toBe(3.3 * GB);
    expect(budget.measuredAvailableBytes).toBe(0);
  });

  it('scales the floor with RAM and never exceeds the RAM itself', () => {
    const floorFor = (ramGiB: number) =>
      computeMemoryBudget(ios(ramGiB, 0), policy).availableBytes;
    expect(floorFor(3.75)).toBe(1.4 * GB);
    expect(floorFor(5.6)).toBe(3.0 * GB);
    expect(floorFor(7.5)).toBe(3.0 * GB);
    expect(floorFor(1)).toBe(1 * GiB);
  });
});

describe('memory budget: Android and the #982 floor', () => {
  it('ignores a 2 GB first-launch reading on a 12 GB flagship', () => {
    // PocketPal #982: an S25 Ultra "sees 2 GB" and is stuck with tiny models.
    const budget = computeMemoryBudget(android(11.2, 2.0), policy);
    expect(budget.source).toBe('floor');
    expect(budget.measuredAvailableBytes).toBe(2.0 * GB);
    expect(budget.availableBytes).toBeCloseTo(0.7 * 11.2 * GiB);
    expect(budget.shared).toBe(true);
    expect(budget.dirtyPoolBytes).toBe(budget.weightsPoolBytes);
  });

  it('uses a reading above the floor', () => {
    const budget = computeMemoryBudget(android(11.2, 9.5), policy);
    expect(budget.source).toBe('measured');
    expect(budget.availableBytes).toBe(9.5 * GB);
  });

  it('caps a reading above physical RAM', () => {
    const budget = computeMemoryBudget(android(8, 64), policy);
    expect(budget.availableBytes).toBe(8 * GiB);
  });

  it('floors by RAM share, limited by the OS reserve', () => {
    expect(androidFloorBytes(3.6 * GiB, policy)).toBeCloseTo(1.8 * GiB);
    expect(androidFloorBytes(7.4 * GiB, policy)).toBeCloseTo(0.6 * 7.4 * GiB);
    expect(androidFloorBytes(15 * GiB, policy)).toBeCloseTo(0.7 * 15 * GiB);
    // 2 GiB phone: the reserve (1.5 GiB) bites before the 50% share does.
    expect(androidFloorBytes(2 * GiB, policy)).toBeCloseTo(2 * GiB - 1500 * MB);
    expect(androidFloorBytes(1 * GiB, policy)).toBe(0);
  });

  it('handles a failed read', () => {
    const budget = computeMemoryBudget(android(7.4, undefined), policy);
    expect(budget.source).toBe('floor');
    expect(budget.measuredAvailableBytes).toBe(0);
  });
});

describe('stepValue', () => {
  const steps = [
    {maxRamBytes: 10, v: 1},
    {maxRamBytes: 20, v: 2},
    {maxRamBytes: null, v: 3},
  ];
  it('picks the first step at or above the value', () => {
    expect(stepValue(steps, 10, 'v')).toBe(1);
    expect(stepValue(steps, 11, 'v')).toBe(2);
    expect(stepValue(steps, 999, 'v')).toBe(3);
  });
  it('uses the last step when none is open-ended', () => {
    expect(stepValue(steps.slice(0, 2), 999, 'v')).toBe(2);
  });
});

describe('device class', () => {
  it('is driven by measured memory, not by the RAM on the box', () => {
    // Same 12 GB iPhone, three launch readings.
    expect(profile(ios(11.45, 3.17)).deviceClass).toBe('D');
    expect(profile(ios(11.45, 2.5)).deviceClass).toBe('C');
    expect(profile(ios(11.45, 1.0)).deviceClass).toBe('A');
  });

  it('never reaches E on a 12 GB iPhone: the weights would not fit', () => {
    const device = profile(ios(11.45, 7.8));
    expect(device.memoryClass).toBe('D');
    expect(device.deviceClass).toBe('D');
  });

  it('caps a slow chip below what its memory would allow', () => {
    // Pixel 9: 12 GB but a Tensor G4 (PocketPal tier "high").
    const pixel = profile(android(11.2, 5, 'Tensor G4'));
    expect(pixel.memoryClass).toBe('D');
    expect(pixel.upstreamTier).toBe('high');
    expect(pixel.chipClass).toBe('C');
    expect(pixel.deviceClass).toBe('C');
  });

  it('caps a strong chip by memory', () => {
    const device = profile(ios(11.45, 2.5));
    expect(device.chipClass).toBe('E');
    expect(device.memoryClass).toBe('C');
  });

  it('strips the MediaTek vendor suffix through the upstream rules', () => {
    expect(upstreamTierFor(android(3.6, 1.5, 'MT6769V/CZ'))).toBe('low');
  });

  it('classifies an unknown iPhone by family', () => {
    expect(upstreamTierFor(ios(11.45, 3, 'iPhone19,1'))).toBe('flagship');
  });

  it('gives an unclassifiable device the lowest class', () => {
    const device = profile({
      platform: 'android',
      osVersion: '',
      totalRamBytes: 0,
    });
    expect(device.deviceClass).toBe('A');
    expect(device.osMajor).toBe(0);
  });

  it('accepts injected chip tables', () => {
    const tables = upstreamClassifiers();
    const allLow = {
      ...tables,
      ios: {...tables.ios, tierMatrix: []},
    };
    expect(
      classifyDevice(ios(11.45, 3.17), bundledCatalog, allLow).deviceClass,
    ).toBe('A');
  });

  it('exposes helpers', () => {
    expect(lowerClass('B', 'D')).toBe('B');
    expect(lowerClass('E', 'C')).toBe('C');
    expect(osMajorOf('26.6.2')).toBe(26);
    expect(osMajorOf('unknown')).toBe(0);
    expect(
      memoryClassFor(
        computeMemoryBudget(android(15, 2), policy),
        bundledCatalog,
      ),
    ).toBe('E');
  });
});

describe('GPU hint', () => {
  it('uses Metal on iOS 18 and later, also on 4 GB iPhones', () => {
    expect(gpuHintFor(ios(11.45, 3), policy)).toEqual({
      backend: 'metal',
      maxGpuLayers: 99,
    });
    expect(gpuHintFor(ios(3.75, 2), policy).backend).toBe('metal');
  });

  it('stays on the CPU before iOS 18 and on the Simulator', () => {
    expect(
      gpuHintFor(ios(5.6, 3, 'iPhone14,2', {osVersion: '17.7'}), policy),
    ).toEqual({backend: 'cpu', reason: 'os_too_old', maxGpuLayers: 0});
    expect(
      gpuHintFor(ios(11.45, 0, 'iPhone18,1', {isEmulator: true}), policy)
        .reason,
    ).toBe('emulator');
  });

  it('uses OpenCL only on Adreno 700+ with i8mm and dotprod', () => {
    expect(gpuHintFor(android(11.2, 5), policy)).toEqual({
      backend: 'opencl',
      maxGpuLayers: 24,
    });
    const hint = (extra: object) =>
      gpuHintFor(android(11.2, 5, 'x', extra), policy);
    expect(hint({gpuRenderer: 'Mali-G715'}).reason).toBe('no_adreno');
    expect(hint({gpuRenderer: undefined}).reason).toBe('no_adreno');
    expect(hint({gpuRenderer: 'Adreno (TM) 660'}).reason).toBe(
      'adreno_too_old',
    );
    expect(hint({cpuFeatures: ['asimddp']}).reason).toBe(
      'missing_cpu_features',
    );
    expect(hint({cpuFeatures: ['i8mm']}).reason).toBe('missing_cpu_features');
    expect(hint({cpuFeatures: undefined}).reason).toBe('missing_cpu_features');
    expect(hint({cpuFeatures: ['dotprod', 'i8mm']}).backend).toBe('opencl');
  });

  it('caps Adreno layers by RAM', () => {
    expect(gpuHintFor(android(7.4, 3), policy).maxGpuLayers).toBe(12);
    expect(gpuHintFor(android(5.5, 3), policy)).toEqual({
      backend: 'cpu',
      reason: 'low_memory',
      maxGpuLayers: 0,
    });
    expect(gpuHintFor(android(3.6, 1.5), policy).reason).toBe('low_memory');
  });

  it('reads the Adreno generation', () => {
    expect(adrenoGeneration('Adreno (TM) 750')).toBe(750);
    expect(adrenoGeneration('adreno 830')).toBe(830);
    expect(adrenoGeneration('Mali-G715')).toBeNull();
    expect(adrenoGeneration(undefined)).toBeNull();
  });
});

describe('known issues', () => {
  it('flags iOS 27.2.1 (llama.rn #439) and nothing else', () => {
    const at = (osVersion: string) =>
      knownIssuesFor(ios(11.45, 3, 'iPhone18,2', {osVersion}));
    expect(at('27.2.1')).toEqual(['llama.rn#439']);
    expect(at('27.2')).toEqual([]);
    expect(at('27.2.10')).toEqual([]);
    expect(at('26.6.2')).toEqual([]);
    expect(knownIssuesFor({...android(8, 3), osVersion: '27.2.1'})).toEqual([]);
  });
});
