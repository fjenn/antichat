import {DeviceEventEmitter, Platform} from 'react-native';

import NativeDownloadModule from '../../../specs/NativeDownloadModule';

import {
  antichatNative,
  antichatNativeEvents,
  NativeDownloadInfo,
  NativeEventSource,
  NativeStartParams,
} from './native';

/**
 * One resumable, background-safe file download on either platform.
 *
 * iOS: `AntiChatNative` (background URLSession, resume data; port of Off Grid's
 * download manager). Android: upstream's `DownloadModule` (WorkManager, HTTP
 * Range into `<destination>.part`). Both key a download by its destination, so
 * calling `start` again after the app was killed continues the same download.
 */
export interface FileDownloadRequest extends NativeStartParams {
  /** Android: only download on unmetered networks. */
  wifiOnly?: boolean;
}

export interface FileDownload {
  /** Settles when the file is in place at `destination`. */
  done: Promise<void>;
  pause(): void;
  resume(): void;
  /** Stops the download and keeps its bytes for a later `start`; `done` rejects. */
  stop(): void;
  /** Stops and forgets the download; `done` rejects. */
  cancel(): void;
}

export class DownloadError extends Error {
  constructor(
    message: string,
    readonly code: string = 'download_failed',
  ) {
    super(message);
    this.name = 'DownloadError';
  }
}

interface Live {
  onProgress: (bytes: number, total: number) => void;
  resolve: () => void;
  reject: (error: Error) => void;
}

interface ProgressEvent {
  downloadId: string;
  bytesWritten: number;
  totalBytes: number;
}

const live = new Map<string, Live>();
let listening = false;

function listen(): void {
  if (listening) {
    return;
  }
  listening = true;
  // Android's module emits through the device event emitter; iOS through ours.
  const events: NativeEventSource | undefined =
    Platform.OS === 'ios'
      ? antichatNativeEvents()
      : (DeviceEventEmitter as unknown as NativeEventSource);
  events?.addListener('onDownloadProgress', (event: ProgressEvent) => {
    live
      .get(event.downloadId)
      ?.onProgress(event.bytesWritten, event.totalBytes);
  });
  events?.addListener('onDownloadComplete', (event: {downloadId: string}) => {
    const entry = live.get(event.downloadId);
    live.delete(event.downloadId);
    entry?.resolve();
  });
  events?.addListener(
    'onDownloadFailed',
    (event: {downloadId: string; error?: string; code?: string}) => {
      const entry = live.get(event.downloadId);
      live.delete(event.downloadId);
      entry?.reject(
        new DownloadError(event.error ?? 'Download failed', event.code),
      );
    },
  );
}

async function startNative(request: FileDownloadRequest): Promise<string> {
  if (Platform.OS === 'ios') {
    if (!antichatNative?.startDownload) {
      throw new DownloadError('AntiChatNative is not linked', 'no_native');
    }
    return (await antichatNative.startDownload(request)).downloadId;
  }
  const response = await NativeDownloadModule.startDownload(request.url, {
    destination: request.destination,
    networkType: request.wifiOnly ? 'WIFI' : 'ANY',
    priority: 1,
    progressInterval: 500,
  });
  return response.downloadId;
}

const nativePause = (id: string) =>
  Platform.OS === 'ios'
    ? antichatNative?.pauseDownload?.(id)
    : NativeDownloadModule.pauseDownload(id);
const nativeResume = (id: string) =>
  Platform.OS === 'ios'
    ? antichatNative?.resumeDownload?.(id)
    : NativeDownloadModule.resumeDownload(id);
const nativeCancel = (id: string) =>
  Platform.OS === 'ios'
    ? antichatNative?.cancelDownload?.(id)
    : NativeDownloadModule.cancelDownload(id);

export function startFileDownload(
  request: FileDownloadRequest,
  onProgress: (bytes: number, total: number) => void,
): FileDownload {
  listen();
  let id: string | null = null;
  let cancelled = false;
  let wantPaused = false;
  let settle!: Live;
  const done = new Promise<void>((resolve, reject) => {
    settle = {onProgress, resolve, reject};
  });
  // Never an unhandled rejection: callers await `done` when they care.
  done.catch(() => undefined);

  const started = startNative(request).then(
    downloadId => {
      id = downloadId;
      if (cancelled) {
        Promise.resolve(nativeCancel(downloadId)).catch(() => undefined);
        return;
      }
      live.set(downloadId, settle);
      if (wantPaused) {
        Promise.resolve(nativePause(downloadId)).catch(() => undefined);
      }
    },
    (error: unknown) => {
      settle.reject(
        error instanceof Error ? error : new DownloadError(String(error)),
      );
    },
  );

  const whenStarted = (work: (downloadId: string) => unknown) => {
    started.then(() => {
      if (id !== null && !cancelled) {
        Promise.resolve(work(id)).catch(() => undefined);
      }
    });
  };

  return {
    done,
    pause() {
      wantPaused = true;
      whenStarted(nativePause);
    },
    resume() {
      wantPaused = false;
      whenStarted(nativeResume);
    },
    stop() {
      if (cancelled) {
        return;
      }
      // Paused natively (resume data on iOS, the .part file on Android): the
      // next `startFileDownload` for this destination continues from there.
      whenStarted(downloadId => {
        live.delete(downloadId);
        return nativePause(downloadId);
      });
      started.then(() => {
        cancelled = true;
      });
      settle.reject(new DownloadError('Download stopped', 'stopped'));
    },
    cancel() {
      if (cancelled) {
        return;
      }
      const downloadId = id;
      cancelled = true;
      if (downloadId !== null) {
        live.delete(downloadId);
        Promise.resolve(nativeCancel(downloadId)).catch(() => undefined);
      }
      settle.reject(new DownloadError('Download cancelled', 'cancelled'));
    },
  };
}

/** Bytes a native download has for this destination (iOS; 0 when unknown). */
export async function nativeBytesFor(destination: string): Promise<number> {
  const info = await nativeDownloadFor(destination);
  return info?.bytesWritten ?? 0;
}

export async function nativeDownloadFor(
  destination: string,
): Promise<NativeDownloadInfo | undefined> {
  if (Platform.OS !== 'ios' || !antichatNative?.getDownloads) {
    return undefined;
  }
  const all = await antichatNative.getDownloads();
  return all.find(d => d.destination === destination);
}

/** Forget whatever the native side knows about this destination. */
export async function forgetNativeDownload(destination: string): Promise<void> {
  if (Platform.OS === 'ios') {
    const info = await nativeDownloadFor(destination);
    if (info) {
      await antichatNative?.cancelDownload?.(info.downloadId);
    }
    return;
  }
  const active = await NativeDownloadModule.getActiveDownloads();
  await Promise.all(
    active
      .filter(d => d.destination === destination)
      .map(d => NativeDownloadModule.cancelDownload(d.id)),
  );
}
