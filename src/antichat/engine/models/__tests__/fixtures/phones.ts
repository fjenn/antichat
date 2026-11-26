import type {DeviceClass} from '../../catalog/types';
import type {DeviceSnapshot} from '../../device/types';

/**
 * Real phones for the table-driven policy test and docs/antichat/m5-device-table.md.
 *
 * `basis` says how much of the memory reading is real:
 *  - measured:  read on the device by our spike harness
 *  - published: a figure someone else measured and published (research doc 03, section 2)
 *  - assumed:   no measurement exists; a typical value for the RAM size
 * The policy only ever sees the reading, so replacing an assumed row with a
 * measured one is a one-line change here.
 */
export interface PhoneCase {
  name: string;
  marketedRamGb: number;
  chip: string;
  basis: 'measured' | 'published' | 'assumed';
  snapshot: DeviceSnapshot;
  expected: {
    deviceClass: DeviceClass;
    modelId: string;
    contextSize: number;
    vision: boolean;
    unrestrictedId: string | null;
    upgradeOfferId?: string;
  };
  note?: string;
}

const GiB = 1024 ** 3;
const GB = 1000 ** 3;

/** What iOS reports as physical memory for each marketed size. */
const IOS_TOTAL: Record<number, number> = {
  4: 3.75 * GiB,
  6: 5.6 * GiB,
  8: 7.5 * GiB,
  // Read on an iPhone 17 Pro (spike, 2026-11-24).
  12: 12290424832,
};

/** What Android reports as total memory for each marketed size. */
const ANDROID_TOTAL: Record<number, number> = {
  4: 3.6 * GiB,
  6: 5.5 * GiB,
  8: 7.4 * GiB,
  12: 11.2 * GiB,
  16: 15.0 * GiB,
};

type Expected = PhoneCase['expected'];

function iphone(
  name: string,
  machine: string,
  chip: string,
  ramGb: number,
  availableBytes: number,
  basis: PhoneCase['basis'],
  expected: Expected,
  extra: {osVersion?: string; note?: string; isEmulator?: boolean} = {},
): PhoneCase {
  return {
    name,
    marketedRamGb: ramGb,
    chip,
    basis,
    note: extra.note,
    expected,
    snapshot: {
      platform: 'ios',
      osVersion: extra.osVersion ?? '26.6',
      totalRamBytes: IOS_TOTAL[ramGb],
      availableBytes,
      freeStorageBytes: 64 * GB,
      machine,
      isEmulator: extra.isEmulator,
    },
  };
}

const SNAPDRAGON_FEATURES = ['fp', 'asimd', 'asimddp', 'i8mm', 'sve2'];
const BASIC_FEATURES = ['fp', 'asimd', 'asimddp'];

function android(
  name: string,
  socModel: string,
  chip: string,
  ramGb: number,
  expected: Expected,
  extra: {
    gpuRenderer?: string;
    availableBytes?: number;
    cpuFeatures?: string[];
    hardware?: string;
    note?: string;
  } = {},
): PhoneCase {
  const total = ANDROID_TOTAL[ramGb];
  return {
    name,
    marketedRamGb: ramGb,
    chip,
    basis: 'assumed',
    note: extra.note,
    expected,
    snapshot: {
      platform: 'android',
      osVersion: '16',
      totalRamBytes: total,
      // A typical reading with a few apps in the background.
      availableBytes: extra.availableBytes ?? total * 0.4,
      freeStorageBytes: 64 * GB,
      socModel,
      hardware: extra.hardware,
      cpuFeatures: extra.cpuFeatures ?? BASIC_FEATURES,
      gpuRenderer: extra.gpuRenderer ?? 'Mali-G715',
    },
  };
}

const LFM = 'lfm3-1.7b';
const E2B = 'gemma-4-e2b-qat';
const E4B = 'gemma-4-e4b-qat';
const Q9B = 'qwen3.5-9b';
const U_LFM = null;
const U_Q4B = 'qwen3.5-4b-unrestricted';
const U_E4B = 'gemma-4-e4b-unrestricted';
const U_12B = 'gemma-4-e4b-unrestricted';

const A: Expected = {
  deviceClass: 'A',
  modelId: LFM,
  contextSize: 4096,
  vision: false,
  unrestrictedId: U_LFM,
};
const B: Expected = {
  deviceClass: 'B',
  modelId: LFM,
  contextSize: 8192,
  vision: false,
  unrestrictedId: U_LFM,
  upgradeOfferId: E2B,
};
const C: Expected = {
  deviceClass: 'C',
  modelId: E2B,
  contextSize: 8192,
  vision: true,
  unrestrictedId: U_Q4B,
};
const D: Expected = {
  deviceClass: 'D',
  modelId: E4B,
  contextSize: 16384,
  vision: true,
  unrestrictedId: U_E4B,
};
const E: Expected = {
  deviceClass: 'E',
  modelId: Q9B,
  contextSize: 16384,
  vision: true,
  unrestrictedId: U_12B,
};

export const PHONES: PhoneCase[] = [
  // ---- iPhone, 4 GB ----
  iphone('iPhone 12 mini', 'iPhone13,1', 'A14', 4, 2.0 * GB, 'assumed', A),
  iphone('iPhone 12', 'iPhone13,2', 'A14', 4, 2.0 * GB, 'assumed', A),
  iphone('iPhone 13', 'iPhone14,5', 'A15', 4, 2.1 * GB, 'published', A),
  iphone(
    'iPhone SE (3rd gen)',
    'iPhone14,6',
    'A15',
    4,
    1.4 * GB,
    'published',
    A,
  ),
  // ---- iPhone, 6 GB ----
  iphone('iPhone 12 Pro', 'iPhone13,3', 'A14', 6, 3.12 * GB, 'assumed', B),
  iphone('iPhone 13 Pro', 'iPhone14,2', 'A15', 6, 3.12 * GB, 'published', B),
  iphone('iPhone 14', 'iPhone14,7', 'A15', 6, 3.12 * GB, 'assumed', B),
  iphone('iPhone 14 Pro', 'iPhone15,2', 'A16', 6, 3.12 * GB, 'assumed', B),
  iphone('iPhone 15', 'iPhone15,4', 'A16', 6, 3.12 * GB, 'assumed', B),
  // ---- iPhone, 8 GB ----
  iphone('iPhone 15 Pro', 'iPhone16,1', 'A17 Pro', 8, 3.0 * GB, 'assumed', C),
  iphone('iPhone 16', 'iPhone17,3', 'A18', 8, 3.0 * GB, 'assumed', C),
  iphone('iPhone 16e', 'iPhone17,5', 'A18', 8, 3.0 * GB, 'assumed', C),
  iphone('iPhone 16 Pro', 'iPhone17,1', 'A18 Pro', 8, 3.0 * GB, 'assumed', C),
  iphone('iPhone 17', 'iPhone18,3', 'A19', 8, 3.0 * GB, 'assumed', C),
  // ---- iPhone, 12 GB ----
  iphone(
    'iPhone 17 Pro',
    'iPhone18,1',
    'A19 Pro',
    12,
    3165633304,
    'measured',
    D,
    {
      osVersion: '26.6.2',
      note: 'Our spike phone: 3.17 GB available at launch.',
    },
  ),
  iphone('iPhone Air', 'iPhone18,4', 'A19 Pro', 12, 3165633304, 'assumed', D),
  iphone(
    'iPhone 17 Pro Max',
    'iPhone18,2',
    'A19 Pro',
    12,
    7.8 * GB,
    'published',
    {...D, upgradeOfferId: Q9B},
    {
      osVersion: '27.2',
      note: 'Raised memory limit in force (8,192 MiB): the 9B is offered.',
    },
  ),
  iphone(
    'iPhone 18 Pro',
    'iPhone19,1',
    'A20 Pro',
    12,
    3165633304,
    'assumed',
    D,
    {
      osVersion: '27.1',
      note: 'Identifier not in the chip table yet: classified by family.',
    },
  ),
  iphone('iOS Simulator', 'iPhone18,1', '(host)', 12, 0, 'measured', D, {
    osVersion: '27.0',
    isEmulator: true,
    note: 'Reports 0 available: the per-RAM floor is used, CPU only.',
  }),

  // ---- Android, 4 GB ----
  android('Redmi 13C', 'MT6769V/CZ', 'Helio G85', 4, A, {
    gpuRenderer: 'Mali-G52 MC2',
    cpuFeatures: ['fp', 'asimd'],
  }),
  android('Galaxy A16', 'MT6789', 'Helio G99', 4, A, {
    gpuRenderer: 'Mali-G57 MC2',
  }),
  // ---- Android, 6-8 GB mid-range ----
  android('Galaxy A35', 's5e8835', 'Exynos 1380', 6, A, {
    gpuRenderer: 'Mali-G68 MP5',
    note: 'Mid chip at 6 GB: PocketPal tier low.',
  }),
  android('Galaxy A55', 's5e8845', 'Exynos 1480', 8, B, {
    gpuRenderer: 'Xclipse 530',
  }),
  android('Galaxy A56', 's5e8855', 'Exynos 1580', 8, B, {
    gpuRenderer: 'Xclipse 540',
  }),
  android('Pixel 8a', 'Tensor G3', 'Tensor G3', 8, B, {
    hardware: 'akita',
    gpuRenderer: 'Mali-G715',
  }),
  // ---- Android, 12 GB Pixel ----
  android('Pixel 9', 'Tensor G4', 'Tensor G4', 12, C, {
    hardware: 'tokay',
    gpuRenderer: 'Mali-G715',
  }),
  android('Pixel 10', 'Tensor G5', 'Tensor G5', 12, C, {
    gpuRenderer: 'PowerVR DXT-48-1536',
  }),
  // ---- Android, flagship ----
  android('Galaxy S23', 'SM8550', 'Snapdragon 8 Gen 2', 8, C, {
    gpuRenderer: 'Adreno (TM) 740',
    cpuFeatures: SNAPDRAGON_FEATURES,
  }),
  android('Galaxy S24', 'SM8650', 'Snapdragon 8 Gen 3', 8, C, {
    gpuRenderer: 'Adreno (TM) 750',
    cpuFeatures: SNAPDRAGON_FEATURES,
  }),
  android('Galaxy S24 Ultra', 'SM8650', 'Snapdragon 8 Gen 3', 12, D, {
    gpuRenderer: 'Adreno (TM) 750',
    cpuFeatures: SNAPDRAGON_FEATURES,
  }),
  android('Galaxy S25', 'SM8750', 'Snapdragon 8 Elite', 12, D, {
    gpuRenderer: 'Adreno (TM) 830',
    cpuFeatures: SNAPDRAGON_FEATURES,
  }),
  android('Galaxy S25 Ultra', 'SM8750', 'Snapdragon 8 Elite', 12, D, {
    gpuRenderer: 'Adreno (TM) 830',
    cpuFeatures: SNAPDRAGON_FEATURES,
    availableBytes: 2.0 * GB,
    note: 'PocketPal #982: reads 2 GB at first launch. The floor keeps it in D.',
  }),
  android('OnePlus 13 (16 GB)', 'SM8750', 'Snapdragon 8 Elite', 16, E, {
    gpuRenderer: 'Adreno (TM) 830',
    cpuFeatures: SNAPDRAGON_FEATURES,
  }),
];
