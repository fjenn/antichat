/**
 * The connectivity port of this build: the phone's real network state (M5's
 * `ConnectivityStore` over NetInfo), with the scripted scenario able to
 * override it so cellular and offline can be shown on a simulator.
 */
import type {Connectivity} from '../../../contracts';
import {
  ConnectivityStore,
  netInfoSource,
  type ConnectivitySource,
  type NetInfoLike,
  type NetInfoStateLike,
} from '../../../engine/connectivity';
import type {Scenario} from './scenario';

const ALWAYS_ON_WIFI: ConnectivitySource = {
  read: async () => ({connected: true, kind: 'wifi', expensive: false}),
  subscribe: () => () => {},
};

function realSource(): ConnectivitySource {
  try {
    const NetInfo: NetInfoLike & {
      configure?: (config: Record<string, unknown>) => void;
    } = require('@react-native-community/netinfo').default;
    // No reachability probe: the app makes no request the user did not cause.
    NetInfo.configure?.({reachabilityShouldRun: () => false});
    // With the probe off NetInfo reports `isInternetReachable: false` for
    // every state, so that field is dropped before the reading is taken.
    const withoutReachability = (
      state: NetInfoStateLike,
    ): NetInfoStateLike => ({
      type: state.type,
      isConnected: state.isConnected,
      isInternetReachable: null,
      details: state.details,
    });
    return netInfoSource({
      fetch: async () => withoutReachability(await NetInfo.fetch()),
      addEventListener: listener =>
        NetInfo.addEventListener(state => listener(withoutReachability(state))),
    });
  } catch {
    return ALWAYS_ON_WIFI;
  }
}

export class ScriptedConnectivity implements Connectivity {
  private readonly real: ConnectivityStore;
  private readonly listeners = new Set<() => void>();
  private started: Promise<void> | null = null;

  constructor(
    private readonly scenario: Scenario,
    source: ConnectivitySource = realSource(),
  ) {
    this.real = new ConnectivityStore(source);
    this.real.subscribe(() => this.emit());
    this.scenario.subscribe(() => this.emit());
  }

  get online(): boolean {
    switch (this.scenario.network) {
      case 'offline':
        return false;
      case 'wifi':
      case 'cellular':
        return true;
      default:
        return this.real.online;
    }
  }

  get metered(): boolean {
    switch (this.scenario.network) {
      case 'cellular':
        return true;
      case 'wifi':
        return false;
      default:
        return this.real.metered;
    }
  }

  get status(): {online: boolean; metered: boolean} {
    return {online: this.online, metered: this.metered};
  }

  start(): Promise<void> {
    this.started ??= this.real.start();
    return this.started;
  }

  async refresh(): Promise<void> {
    await this.start();
    this.emit();
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
