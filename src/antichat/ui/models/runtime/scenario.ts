/**
 * What the scripted model backend plays. Debug builds change it from
 * Settings > Advanced; tests set it directly. Stored, so a scenario survives a
 * restart (a download that was cut off must still be cut off afterwards).
 */
import AsyncStorage from '@react-native-async-storage/async-storage';
import {makeAutoObservable, runInAction} from 'mobx';

export type ScenarioSpeed = 'demo' | 'wifi' | 'slow';
export type ScenarioNetwork = 'real' | 'wifi' | 'cellular' | 'offline';
export type ScenarioStorage = 'real' | 'tight' | 'full';
export type ScenarioDevice = 'real' | 'small' | 'mid' | 'large';
export type ScenarioFailure = 'none' | 'network' | 'checksum' | 'load';

export interface ScenarioValues {
  speed: ScenarioSpeed;
  network: ScenarioNetwork;
  storage: ScenarioStorage;
  device: ScenarioDevice;
  /** Happens once, on the next download or load, then resets to `none`. */
  failure: ScenarioFailure;
}

export const DEFAULT_SCENARIO: ScenarioValues = {
  speed: 'demo',
  network: 'real',
  storage: 'real',
  device: 'real',
  failure: 'none',
};

/** Bytes per second. `demo` is capped per file, see `ScriptedBackend.rateFor`. */
export const SPEED_BYTES_PER_SECOND: Record<ScenarioSpeed, number> = {
  demo: 45_000_000,
  wifi: 20_000_000,
  slow: 3_500_000,
};

const STORAGE_KEY = 'antichat.scripted.scenario.v1';

export class Scenario implements ScenarioValues {
  speed = DEFAULT_SCENARIO.speed;
  network = DEFAULT_SCENARIO.network;
  storage = DEFAULT_SCENARIO.storage;
  device = DEFAULT_SCENARIO.device;
  failure = DEFAULT_SCENARIO.failure;

  private readonly listeners = new Set<() => void>();

  constructor() {
    makeAutoObservable<Scenario, 'listeners'>(this, {listeners: false});
  }

  async load(): Promise<void> {
    try {
      const raw = await AsyncStorage.getItem(STORAGE_KEY);
      if (raw) {
        const stored = JSON.parse(raw) as Partial<ScenarioValues>;
        runInAction(() =>
          Object.assign(this, {...DEFAULT_SCENARIO, ...stored}),
        );
        this.emit();
      }
    } catch {
      // Unreadable: the defaults play.
    }
  }

  set(patch: Partial<ScenarioValues>): void {
    Object.assign(this, patch);
    this.emit();
    AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(this.values())).catch(
      () => {},
    );
  }

  values(): ScenarioValues {
    return {
      speed: this.speed,
      network: this.network,
      storage: this.storage,
      device: this.device,
      failure: this.failure,
    };
  }

  /** Take the one-shot failure if it is `kind`. */
  consumeFailure(kind: Exclude<ScenarioFailure, 'none'>): boolean {
    if (this.failure !== kind) {
      return false;
    }
    this.set({failure: 'none'});
    return true;
  }

  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  private emit(): void {
    this.listeners.forEach(listener => listener());
  }
}
