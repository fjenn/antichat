/** How the phone is connected, reduced to what the app acts on. */
export type ConnectionKind = 'wifi' | 'cellular' | 'other' | 'none' | 'unknown';

/** One raw reading from the platform. */
export interface NetworkReading {
  /** False only when the platform is sure there is no connection. */
  connected: boolean;
  kind: ConnectionKind;
  /** The platform says traffic is billed by volume (cellular, hotspot). */
  expensive: boolean;
}

/** Where readings come from. Wrapped so the rest of the app never imports NetInfo. */
export interface ConnectivitySource {
  /** Current reading. */
  read(): Promise<NetworkReading>;
  /** Called on every change; returns the unsubscribe function. */
  subscribe(listener: (reading: NetworkReading) => void): () => void;
}

/** The contract the app consumes (`Connectivity` in the shared contracts). */
export interface Connectivity {
  /** The one flag. True until the platform says otherwise. */
  readonly online: boolean;
  /** Hint: downloads should ask before using this connection. */
  readonly metered: boolean;
  readonly kind: ConnectionKind;
  subscribe(listener: () => void): () => void;
}
