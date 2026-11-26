import {NativeModules} from 'react-native';

export type MemoryReading = {
  phys_footprint: number;
  resident_size: number;
  available: number;
  thermal: string;
  thermal_level: number;
};

export type SamplingSummary = {
  peak_phys_footprint: number;
  peak_resident_size: number;
  min_available: number;
  max_thermal: string;
  samples: number;
};

export type ModelFile = {name: string; path: string; size: number};

export type LaunchConfig = {
  enabled: boolean;
  options: Record<string, string>;
  documentsDir: string;
  device: {
    machine: string;
    simulator: boolean;
    os_version: string;
    os_build: string;
    physical_memory: number;
    cores: number;
    low_power_mode: boolean;
  };
};

type SpikeNative = {
  getLaunchConfig(): LaunchConfig;
  getMemory(): Promise<MemoryReading>;
  startSampling(intervalMs: number): void;
  readSampling(): Promise<SamplingSummary>;
  stopSampling(): Promise<SamplingSummary>;
  listModels(dir: string): Promise<ModelFile[]>;
  writeFile(relativePath: string, content: string): Promise<string>;
  readFile(relativePath: string): Promise<string | null>;
  appendLine(relativePath: string, line: string): void;
  setKeepAwake(enabled: boolean): void;
};

// iOS only for now (ios/AntiChat/AntiChatSpikeModule.mm); absent on Android.
export const spikeNative: SpikeNative | undefined = NativeModules.AntiChatSpike;

let cached: LaunchConfig | undefined;

export function getLaunchConfig(): LaunchConfig {
  if (!cached) {
    cached = spikeNative?.getLaunchConfig() ?? {
      enabled: false,
      options: {},
      documentsDir: '',
      device: {
        machine: '',
        simulator: false,
        os_version: '',
        os_build: '',
        physical_memory: 0,
        cores: 0,
        low_power_mode: false,
      },
    };
  }
  return cached;
}
