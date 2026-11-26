/**
 * Drop-in for `@dr.pogodin/react-native-fs` used by upstream's
 * `src/services/downloads/DownloadManager.ts` (its single ANTICHAT edit).
 *
 * Everything is re-exported unchanged, except that on iOS `downloadFile` and
 * `stopDownload` go through our resumable background downloader instead of
 * RNFS's one-shot `NSURLSession` task. Upstream's model screens then get the
 * same downloads as the AntiChat model engine: they continue while the app is
 * suspended, retry after a dropped connection from the bytes already fetched,
 * and re-attach when the same file is requested again after the app was killed.
 */
import * as RNFS from '@dr.pogodin/react-native-fs';
import {Platform} from 'react-native';

import {FileDownload, startFileDownload} from './fileDownloader';
import {antichatNative} from './native';

export * from '@dr.pogodin/react-native-fs';

type Options = Parameters<typeof RNFS.downloadFile>[0];
type Result = ReturnType<typeof RNFS.downloadFile>;

const resumable = () =>
  Platform.OS === 'ios' && antichatNative?.startDownload !== undefined;

// Our job ids start far above RNFS's own counter, so `stopDownload` can tell
// whose job it was given.
const FIRST_JOB_ID = 1_000_000;
let nextJobId = FIRST_JOB_ID;
const jobs = new Map<number, FileDownload>();

export function downloadFile(options: Options): Result {
  if (!resumable()) {
    return RNFS.downloadFile(options);
  }
  const jobId = nextJobId++;
  let begun = false;
  let lastBytes = 0;
  const download = startFileDownload(
    {
      url: options.fromUrl,
      destination: options.toFile,
      headers: options.headers as Record<string, string> | undefined,
    },
    (bytesWritten, contentLength) => {
      lastBytes = bytesWritten;
      if (!begun) {
        begun = true;
        options.begin?.({jobId, statusCode: 200, contentLength, headers: {}});
      }
      options.progress?.({jobId, contentLength, bytesWritten});
    },
  );
  jobs.set(jobId, download);
  const promise = download.done.then(
    async () => {
      jobs.delete(jobId);
      const size = await RNFS.stat(options.toFile)
        .then(stat => Number(stat.size) || lastBytes)
        .catch(() => lastBytes);
      return {jobId, statusCode: 200, bytesWritten: size};
    },
    (error: unknown) => {
      jobs.delete(jobId);
      throw error;
    },
  );
  return {jobId, promise};
}

export function stopDownload(jobId: number): void {
  const download = jobs.get(jobId);
  if (download) {
    jobs.delete(jobId);
    download.cancel();
    return;
  }
  RNFS.stopDownload(jobId);
}
