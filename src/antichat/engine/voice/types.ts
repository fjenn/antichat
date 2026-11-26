/** Shared shapes of the voice engine. Everything here is plain data. */

/** Capability class from the device table (docs/antichat/m5-device-table.md). */
export type VoiceDeviceClass = 'A' | 'B' | 'C' | 'D' | 'E';
export type VoicePlatform = 'ios' | 'android';

/** All speech audio inside the engine: 16 kHz mono signed 16-bit. */
export const SAMPLE_RATE = 16_000;
export const SAMPLES_PER_MS = SAMPLE_RATE / 1000;

export type VoiceErrorCode =
  | 'permission_denied'
  | 'mic_unavailable'
  | 'model_missing'
  | 'out_of_memory'
  | 'unsupported'
  | 'cancelled'
  | 'timeout'
  | 'failed';

/** Errors the UI words itself; `detail` is for logs only. */
export interface VoiceError {
  code: VoiceErrorCode;
  retryable: boolean;
  detail?: string;
}

export const voiceError = (
  code: VoiceErrorCode,
  detail?: unknown,
  retryable = code === 'timeout' || code === 'failed',
): VoiceError => ({
  code,
  retryable,
  detail:
    detail === undefined
      ? undefined
      : detail instanceof Error
        ? detail.message
        : String(detail),
});

/** Wall clock and timers, injected so tests and the harness can control time. */
export interface Clock {
  now(): number;
  setTimeout(fn: () => void, ms: number): unknown;
  clearTimeout(handle: unknown): void;
}

export const systemClock: Clock = {
  now: () => Date.now(),
  setTimeout: (fn, ms) => setTimeout(fn, ms),
  clearTimeout: handle =>
    clearTimeout(handle as ReturnType<typeof setTimeout> | undefined),
};

export type Unsubscribe = () => void;

/** Minimal typed event hub. */
export class Hub<E> {
  private readonly listeners = new Set<(event: E) => void>();

  on = (listener: (event: E) => void): Unsubscribe => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };

  emit(event: E): void {
    this.listeners.forEach(listener => listener(event));
  }
}
