import {Platform} from 'react-native';
import DeviceInfo from 'react-native-device-info';

import {readDeviceSnapshot} from '../device/probe';
import NativeHardwareInfo from '../../../../specs/NativeHardwareInfo';

const hardware = NativeHardwareInfo as jest.Mocked<typeof NativeHardwareInfo>;
const info = DeviceInfo as jest.Mocked<typeof DeviceInfo>;
const setPlatform = (os: 'ios' | 'android') => {
  Object.defineProperty(Platform, 'OS', {get: () => os, configurable: true});
};

describe('readDeviceSnapshot', () => {
  const original = Platform.OS;

  beforeEach(() => {
    jest.clearAllMocks();
    info.getTotalMemory.mockResolvedValue(12290424832);
    info.getSystemVersion.mockReturnValue('26.6.2');
    info.getFreeDiskStorage.mockResolvedValue(64e9 as any);
    info.isEmulator.mockResolvedValue(false);
    info.getDeviceId.mockReturnValue('iPhone18,1');
    hardware.getAvailableMemory = jest.fn().mockResolvedValue(3165633304);
  });

  afterAll(() => setPlatform(original as 'ios' | 'android'));

  it('reads an iPhone', async () => {
    setPlatform('ios');
    expect(await readDeviceSnapshot()).toMatchObject({
      platform: 'ios',
      osVersion: '26.6.2',
      totalRamBytes: 12290424832,
      availableBytes: 3165633304,
      freeStorageBytes: 64e9,
      machine: 'iPhone18,1',
      isEmulator: false,
      gpuRenderer: undefined,
    });
  });

  it('reads an Android phone with chip and GPU details', async () => {
    setPlatform('android');
    hardware.getCPUInfo = jest.fn().mockResolvedValue({
      cores: 8,
      socModel: 'SM8750',
      hardware: 'sun',
      features: ['asimddp', 'i8mm'],
      maxFreqMhz: 4320,
    });
    hardware.getGPUInfo = jest
      .fn()
      .mockResolvedValue({renderer: 'Adreno (TM) 830'});
    expect(await readDeviceSnapshot()).toMatchObject({
      platform: 'android',
      socModel: 'SM8750',
      hardware: 'sun',
      cpuFeatures: ['asimddp', 'i8mm', 'dotprod'],
      maxFreqMhz: 4320,
      gpuRenderer: 'Adreno (TM) 830',
    });
  });

  it('degrades when native reads fail instead of throwing', async () => {
    setPlatform('android');
    hardware.getAvailableMemory = jest.fn().mockRejectedValue(new Error('x'));
    hardware.getGPUInfo = jest.fn().mockRejectedValue(new Error('x'));
    hardware.getCPUInfo = jest.fn().mockRejectedValue(new Error('x'));
    info.getFreeDiskStorage.mockRejectedValue(new Error('x'));
    info.isEmulator.mockRejectedValue(new Error('x'));
    const snapshot = await readDeviceSnapshot();
    expect(snapshot.totalRamBytes).toBe(12290424832);
    expect(snapshot.availableBytes).toBeUndefined();
    expect(snapshot.freeStorageBytes).toBeUndefined();
    expect(snapshot.gpuRenderer).toBeUndefined();
    expect(snapshot.isEmulator).toBeUndefined();
  });
});
