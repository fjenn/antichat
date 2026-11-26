import {DeviceEventEmitter, NativeModules, Platform} from 'react-native';

// jest/setup.ts automocks NativeEventEmitter; this suite needs the real one.
jest.unmock('react-native/Libraries/EventEmitter/NativeEventEmitter');

const native = {
  startDownload: jest.fn(async (_params: unknown) => ({
    downloadId: 'job-a',
    reattached: false,
    bytesWritten: 0,
  })),
  pauseDownload: jest.fn(async () => true),
  resumeDownload: jest.fn(async () => true),
  cancelDownload: jest.fn(async () => true),
  getDownloads: jest.fn(async () => []),
  hashFile: jest.fn(),
  memoryInfo: jest.fn(),
  addListener: jest.fn(),
  removeListeners: jest.fn(),
};

const flush = () => new Promise<void>(resolve => setImmediate(resolve));

describe('RNFS drop-in for upstream DownloadManager', () => {
  let RNFS: any;

  beforeEach(() => {
    jest.clearAllMocks();
    jest.resetModules();
    RNFS = require('@dr.pogodin/react-native-fs');
  });

  it('is plain RNFS when our native module is absent', () => {
    Platform.OS = 'ios';
    delete NativeModules.AntiChatNative;
    const shim = require('../rnfsResumable');
    const result = {jobId: 7, promise: Promise.resolve({statusCode: 200})};
    RNFS.downloadFile.mockReturnValueOnce(result);
    const options = {fromUrl: 'https://h/a.gguf', toFile: '/docs/a.gguf'};
    expect(shim.downloadFile(options)).toBe(result);
    expect(RNFS.downloadFile).toHaveBeenCalledWith(options);
    shim.stopDownload(7);
    expect(RNFS.stopDownload).toHaveBeenCalledWith(7);
    // Everything else is RNFS itself.
    expect(shim.mkdir).toBe(RNFS.mkdir);
    expect(shim.DocumentDirectoryPath).toBe(RNFS.DocumentDirectoryPath);
  });

  it('routes iOS downloads through the resumable downloader', async () => {
    Platform.OS = 'ios';
    NativeModules.AntiChatNative = native;
    const shim = require('../rnfsResumable');
    RNFS.stat.mockResolvedValueOnce({size: 1000});
    const begin = jest.fn();
    const progress = jest.fn();
    const {jobId, promise} = shim.downloadFile({
      fromUrl: 'https://huggingface.co/o/r/resolve/main/a.gguf',
      toFile: '/docs/a.gguf',
      headers: {'User-Agent': 'x', Authorization: 'Bearer t'},
      begin,
      progress,
    });
    await flush();
    expect(RNFS.downloadFile).not.toHaveBeenCalled();
    expect(native.startDownload).toHaveBeenCalledWith({
      url: 'https://huggingface.co/o/r/resolve/main/a.gguf',
      destination: '/docs/a.gguf',
      headers: {'User-Agent': 'x', Authorization: 'Bearer t'},
    });
    DeviceEventEmitter.emit('onDownloadProgress', {
      downloadId: 'job-a',
      bytesWritten: 400,
      totalBytes: 1000,
    });
    expect(begin).toHaveBeenCalledWith({
      jobId,
      statusCode: 200,
      contentLength: 1000,
      headers: {},
    });
    expect(progress).toHaveBeenCalledWith({
      jobId,
      contentLength: 1000,
      bytesWritten: 400,
    });
    DeviceEventEmitter.emit('onDownloadComplete', {downloadId: 'job-a'});
    await expect(promise).resolves.toEqual({
      jobId,
      statusCode: 200,
      bytesWritten: 1000,
    });
  });

  it('stopDownload cancels our job and rejects its promise', async () => {
    Platform.OS = 'ios';
    NativeModules.AntiChatNative = native;
    const shim = require('../rnfsResumable');
    const {jobId, promise} = shim.downloadFile({
      fromUrl: 'https://h/a.gguf',
      toFile: '/docs/a.gguf',
    });
    await flush();
    shim.stopDownload(jobId);
    await expect(promise).rejects.toMatchObject({code: 'cancelled'});
    expect(native.cancelDownload).toHaveBeenCalledWith('job-a');
    expect(RNFS.stopDownload).not.toHaveBeenCalled();
  });
});
