import {Platform as RNPlatform} from 'react-native';
import DeviceInfo from 'react-native-device-info';

import {readDeviceSignals} from '../../../../services/deviceRules/signals';
import NativeHardwareInfo from '../../../../specs/NativeHardwareInfo';

import {DeviceSnapshot} from './types';

const orUndefined = async <T>(
  read: () => Promise<T>,
): Promise<T | undefined> => {
  try {
    return await read();
  } catch {
    return undefined;
  }
};

/**
 * Read the phone once. Every native read may fail on its own; a missing value
 * degrades the classification (the memory floor, the CPU backend) instead of
 * failing it.
 */
export async function readDeviceSnapshot(): Promise<DeviceSnapshot> {
  const platform = RNPlatform.OS === 'ios' ? 'ios' : 'android';
  const signals = await readDeviceSignals();
  const [availableBytes, freeStorageBytes, isEmulator, gpu] = await Promise.all(
    [
      orUndefined(() => NativeHardwareInfo.getAvailableMemory()),
      orUndefined(() => DeviceInfo.getFreeDiskStorage()),
      orUndefined(() => DeviceInfo.isEmulator()),
      platform === 'android'
        ? orUndefined(() => NativeHardwareInfo.getGPUInfo())
        : Promise.resolve(undefined),
    ],
  );
  return {
    platform,
    osVersion: String(DeviceInfo.getSystemVersion()),
    totalRamBytes: signals.ramBytes,
    availableBytes,
    freeStorageBytes,
    machine: signals.machine,
    socModel: signals.socModel,
    hardware: signals.hardware,
    cpuFeatures: signals.cpuFeatures,
    maxFreqMhz: signals.maxFreqMhz,
    gpuRenderer: gpu?.renderer,
    isEmulator,
  };
}
