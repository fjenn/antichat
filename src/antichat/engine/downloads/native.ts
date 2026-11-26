import {NativeEventEmitter, NativeModules, Platform} from 'react-native';

/**
 * `AntiChatNative`: our own native module.
 * - iOS (`ios/AntiChat/AntiChatNativeModule.swift`): resumable downloads,
 *   streamed SHA-256, memory reading.
 * - Android (`android/.../antichat/AntiChatNativeModule.kt`): memory-pressure
 *   events, memory reading, streamed SHA-256. Downloads use upstream's module.
 */
export interface NativeDownloadInfo {
  downloadId: string;
  url: string;
  destination: string;
  bytesWritten: number;
  totalBytes: number;
  status: 'running' | 'paused' | 'completed' | 'failed';
  error?: string;
  code?: string;
}

export interface NativeStartParams {
  url: string;
  destination: string;
  totalBytes?: number;
  headers?: Record<string, string>;
  /** Downloads of one model share a group; the notification waits for all. */
  group?: string;
  /** Shown by iOS when the group finishes while the app is not on screen. */
  notifyTitle?: string;
  notifyBody?: string;
}

export interface NativeMemoryInfo {
  availableBytes: number;
  totalBytes: number;
  thresholdBytes?: number;
  lowMemory: boolean;
}

interface AntiChatNativeModule {
  // iOS only
  startDownload?(params: NativeStartParams): Promise<{
    downloadId: string;
    reattached: boolean;
    bytesWritten: number;
  }>;
  pauseDownload?(id: string): Promise<boolean>;
  resumeDownload?(id: string): Promise<boolean>;
  cancelDownload?(id: string): Promise<boolean>;
  getDownloads?(): Promise<NativeDownloadInfo[]>;
  /** UIKit's own application state (see the Swift comment). */
  applicationState?(): Promise<'active' | 'inactive' | 'background'>;
  // both
  hashFile(path: string, token: string): Promise<string>;
  memoryInfo(): Promise<NativeMemoryInfo>;
}

export const antichatNative: AntiChatNativeModule | undefined =
  NativeModules.AntiChatNative;

/** The slice of an event emitter this layer uses, loosely typed. */
export interface NativeEventSource {
  addListener(name: string, listener: (event: any) => void): {remove(): void};
}

let emitter: NativeEventSource | undefined;

/** Events of `AntiChatNative`; undefined when the module is absent (Jest). */
export function antichatNativeEvents(): NativeEventSource | undefined {
  if (!antichatNative) {
    return undefined;
  }
  emitter ??= new NativeEventEmitter(
    Platform.OS === 'ios' ? (antichatNative as any) : undefined,
  ) as unknown as NativeEventSource;
  return emitter;
}
