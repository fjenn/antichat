import {action, makeObservable, observable} from 'mobx';

import {
  ConnectionKind,
  Connectivity,
  ConnectivitySource,
  NetworkReading,
} from './types';

export interface ConnectivityOptions {
  /**
   * How long a lost connection must stay lost before `online` turns false.
   * Rides out the gap when a phone hops between Wi-Fi and cellular, and still
   * shows airplane mode well inside two seconds.
   */
  offlineDelayMs?: number;
  /** How long a regained connection must hold before `online` turns true. */
  onlineDelayMs?: number;
}

const DEFAULT_OFFLINE_DELAY_MS = 1000;
const DEFAULT_ONLINE_DELAY_MS = 300;

/**
 * One observable `online` flag for the whole app, plus a `metered` hint.
 *
 * `online` is debounced in both directions. `metered` and `kind` are not: they
 * describe the connection in use and only matter when a download starts.
 */
export class ConnectivityStore implements Connectivity {
  online = true;
  metered = false;
  kind: ConnectionKind = 'unknown';

  private pendingOnline: boolean | null = null;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private unsubscribe: (() => void) | null = null;
  private readonly listeners = new Set<() => void>();
  private readonly offlineDelayMs: number;
  private readonly onlineDelayMs: number;

  constructor(
    private readonly source: ConnectivitySource,
    options: ConnectivityOptions = {},
  ) {
    this.offlineDelayMs = options.offlineDelayMs ?? DEFAULT_OFFLINE_DELAY_MS;
    this.onlineDelayMs = options.onlineDelayMs ?? DEFAULT_ONLINE_DELAY_MS;
    makeObservable<ConnectivityStore, 'apply' | 'commitOnline'>(this, {
      online: observable,
      metered: observable,
      kind: observable,
      apply: action,
      commitOnline: action,
    });
  }

  /** Begin listening. The first reading is applied without delay. */
  async start(): Promise<void> {
    if (this.unsubscribe) {
      return;
    }
    this.unsubscribe = this.source.subscribe(reading => this.apply(reading));
    try {
      this.apply(await this.source.read(), true);
    } catch {
      // No reading: stay optimistic (online) until an event says otherwise.
    }
  }

  /** Reads the network state again now (pull to retry, app to front). */
  async refresh(): Promise<void> {
    try {
      this.apply(await this.source.read(), true);
    } catch {
      // No reading: keep what we have.
    }
  }

  stop(): void {
    this.unsubscribe?.();
    this.unsubscribe = null;
    this.clearTimer();
    this.pendingOnline = null;
  }

  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  /** For `ModelBackend.network()`. */
  get status(): {online: boolean; metered: boolean} {
    return {online: this.online, metered: this.metered};
  }

  private apply(reading: NetworkReading, immediate = false): void {
    let changed = false;
    // While offline there is no connection to describe: keep the last hint
    // rather than flipping `metered` off for a moment.
    if (reading.connected) {
      changed =
        this.metered !== reading.expensive || this.kind !== reading.kind;
      this.metered = reading.expensive;
      this.kind = reading.kind;
    } else if (this.kind !== 'none' && immediate) {
      this.kind = 'none';
      changed = true;
    }

    if (reading.connected === this.online) {
      // Back to the committed value before the delay ran out: a blip.
      this.clearTimer();
      this.pendingOnline = null;
    } else if (immediate) {
      this.clearTimer();
      this.pendingOnline = null;
      this.online = reading.connected;
      changed = true;
    } else if (this.pendingOnline !== reading.connected) {
      this.clearTimer();
      this.pendingOnline = reading.connected;
      this.timer = setTimeout(
        () => this.commitOnline(),
        reading.connected ? this.onlineDelayMs : this.offlineDelayMs,
      );
    }
    if (changed) {
      this.emit();
    }
  }

  private commitOnline(): void {
    this.timer = null;
    if (this.pendingOnline === null) {
      return;
    }
    this.online = this.pendingOnline;
    this.pendingOnline = null;
    if (!this.online) {
      this.kind = 'none';
    }
    this.emit();
  }

  private clearTimer(): void {
    if (this.timer !== null) {
      clearTimeout(this.timer);
      this.timer = null;
    }
  }

  private emit(): void {
    this.listeners.forEach(listener => listener());
  }
}
