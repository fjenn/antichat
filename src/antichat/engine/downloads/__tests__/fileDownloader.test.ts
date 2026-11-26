import {DeviceEventEmitter, NativeModules, Platform} from 'react-native';

// jest/setup.ts automocks NativeEventEmitter; this suite needs the real one.
jest.unmock('react-native/Libraries/EventEmitter/NativeEventEmitter');

// NativeEventEmitter delivers through the device event emitter, so the test
// emits there, the way the native module's sendEvent does.
const emit = (name: string, event: unknown) =>
  DeviceEventEmitter.emit(name, event);

const native = {
  startDownload: jest.fn(async (_params: unknown) => ({
    downloadId: 'd1',
    reattached: false,
    bytesWritten: 0,
  })),
  pauseDownload: jest.fn(async () => true),
  resumeDownload: jest.fn(async () => true),
  cancelDownload: jest.fn(async () => true),
  getDownloads: jest.fn(async () => [
    {
      downloadId: 'd1',
      url: 'u',
      destination: '/docs/a.gguf',
      bytesWritten: 700,
      totalBytes: 1000,
      status: 'running',
    },
  ]),
  hashFile: jest.fn(async () => 'ABCDEF'),
  memoryInfo: jest.fn(),
  addListener: jest.fn(),
  removeListeners: jest.fn(),
};

const flush = () => new Promise<void>(resolve => setImmediate(resolve));

describe('file downloader (iOS path)', () => {
  let downloads: typeof import('..');

  beforeAll(() => {
    Platform.OS = 'ios';
    NativeModules.AntiChatNative = native;
    downloads = require('..');
  });

  beforeEach(() => {
    jest.clearAllMocks();
  });

  const start = (onProgress = jest.fn()) =>
    downloads.startFileDownload(
      {url: 'http://h/a.gguf', destination: '/docs/a.gguf', totalBytes: 1000},
      onProgress,
    );

  it('reports progress and settles on completion', async () => {
    const onProgress = jest.fn();
    const download = start(onProgress);
    await flush();
    expect(native.startDownload).toHaveBeenCalledWith(
      expect.objectContaining({destination: '/docs/a.gguf', totalBytes: 1000}),
    );
    emit('onDownloadProgress', {
      downloadId: 'd1',
      bytesWritten: 400,
      totalBytes: 1000,
    });
    emit('onDownloadProgress', {
      downloadId: 'other',
      bytesWritten: 1,
      totalBytes: 2,
    });
    expect(onProgress.mock.calls).toEqual([[400, 1000]]);
    emit('onDownloadComplete', {downloadId: 'd1'});
    await expect(download.done).resolves.toBeUndefined();
  });

  it('rejects with the native error and its code', async () => {
    const download = start();
    await flush();
    emit('onDownloadFailed', {
      downloadId: 'd1',
      error: 'The server answered HTTP 503',
      code: 'http_503',
    });
    await expect(download.done).rejects.toMatchObject({
      message: 'The server answered HTTP 503',
      code: 'http_503',
    });
  });

  it('pauses and resumes the native download, also when asked before it started', async () => {
    const download = start();
    download.pause();
    await flush();
    expect(native.pauseDownload).toHaveBeenCalledWith('d1');
    download.resume();
    await flush();
    expect(native.resumeDownload).toHaveBeenCalledWith('d1');
    download.cancel();
    await expect(download.done).rejects.toMatchObject({code: 'cancelled'});
  });

  it('stop keeps the bytes (native pause), cancel forgets them', async () => {
    const stopped = start();
    await flush();
    stopped.stop();
    await expect(stopped.done).rejects.toMatchObject({code: 'stopped'});
    await flush();
    expect(native.pauseDownload).toHaveBeenCalledWith('d1');
    expect(native.cancelDownload).not.toHaveBeenCalled();

    const cancelled = start();
    await flush();
    cancelled.cancel();
    await expect(cancelled.done).rejects.toMatchObject({code: 'cancelled'});
    expect(native.cancelDownload).toHaveBeenCalledWith('d1');
  });

  it('reads the bytes of an in-flight download and forgets one', async () => {
    expect(await downloads.nativeBytesFor('/docs/a.gguf')).toBe(700);
    expect(await downloads.nativeBytesFor('/docs/unknown.gguf')).toBe(0);
    await downloads.forgetNativeDownload('/docs/a.gguf');
    expect(native.cancelDownload).toHaveBeenCalledWith('d1');
  });

  it('hashes natively and lower-cases the digest', async () => {
    expect(await downloads.sha256File('/docs/a.gguf')).toBe('abcdef');
    expect(native.hashFile).toHaveBeenCalledWith(
      '/docs/a.gguf',
      expect.stringMatching(/^hash-/),
    );
  });
});
