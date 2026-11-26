/**
 * Downloader lab: drives a downloader directly (no engine) so the same
 * scenarios (suspend, kill, server loss) can be run against it from the host.
 * Used for the M5 head-to-head; kept as the regression check of the winner.
 *
 *   "lab": {"files": [{"url": "...", "name": "a.gguf", "sizeBytes": 123, "sha256": "..."}],
 *           "pauseAfterBytes": 50000000, "resumeAfterMs": 5000}
 *
 * On every launch each file is either found complete (hashed and reported),
 * or started; starting again after a kill re-attaches to the native download.
 */
import * as RNFS from '@dr.pogodin/react-native-fs';

import {
  nativeDownloadFor,
  sha256File,
  startFileDownload,
} from '../../downloads';

import {DEV_DIR} from './config';
import type {DevLog} from './devLog';

export interface LabFile {
  url: string;
  name: string;
  sizeBytes: number;
  sha256?: string;
}

export interface LabConfig {
  files: LabFile[];
  /** Pause each download once it has this many bytes... */
  pauseAfterBytes?: number;
  /** ...and resume it after this long. */
  resumeAfterMs?: number;
}

export async function runLab(config: LabConfig, log: DevLog): Promise<void> {
  const dir = `${DEV_DIR}/lab`;
  await RNFS.mkdir(dir);
  const summary: Record<string, unknown> = {};
  const writeStatus = (finished: boolean) =>
    log.status({mode: 'lab', finished, files: summary});

  await Promise.all(
    config.files.map(async file => {
      const destination = `${dir}/${file.name}`;
      const record: Record<string, unknown> = {state: 'starting'};
      summary[file.name] = record;
      const finish = async () => {
        const size = Number((await RNFS.stat(destination)).size);
        const started = Date.now();
        const digest = await sha256File(destination);
        Object.assign(record, {
          state: 'done',
          size,
          sizeOk: size === file.sizeBytes,
          sha256: digest,
          shaOk: file.sha256 ? digest === file.sha256 : null,
          hashMs: Date.now() - started,
        });
        log.event('lab_done', {name: file.name, ...record});
        writeStatus(false);
      };

      if (await RNFS.exists(destination)) {
        log.event('lab_found_complete', {name: file.name});
        await finish();
        return;
      }
      const before = await nativeDownloadFor(destination).catch(
        () => undefined,
      );
      log.event('lab_start', {
        name: file.name,
        nativeBefore: before
          ? {status: before.status, bytes: before.bytesWritten}
          : null,
      });
      let paused = false;
      let first = true;
      let lastLogged = 0;
      const download = startFileDownload(
        {url: file.url, destination, totalBytes: file.sizeBytes, group: 'lab'},
        (bytes, total) => {
          if (first) {
            first = false;
            log.event('lab_first_progress', {name: file.name, bytes, total});
          }
          const now = Date.now();
          if (now - lastLogged >= 1000) {
            lastLogged = now;
            log.event('lab_progress', {name: file.name, bytes, total});
            Object.assign(record, {state: 'running', bytes, total});
            writeStatus(false);
          }
          if (
            !paused &&
            config.pauseAfterBytes &&
            bytes >= config.pauseAfterBytes
          ) {
            paused = true;
            download.pause();
            log.event('lab_paused', {name: file.name, bytes});
            setTimeout(() => {
              download.resume();
              log.event('lab_resumed', {name: file.name});
            }, config.resumeAfterMs ?? 5000);
          }
        },
      );
      try {
        await download.done;
        await finish();
      } catch (error) {
        Object.assign(record, {state: 'failed', error: String(error)});
        log.event('lab_failed', {
          name: file.name,
          error: String(error),
          code: (error as {code?: string}).code,
        });
        writeStatus(false);
      }
    }),
  );
  writeStatus(true);
}
