/**
 * Evaluation support: an `HttpGet` that keeps every response on disk, so
 * several models are evaluated on the same pages and the live web is asked
 * once per URL. Never bundled.
 */
import crypto from 'crypto';
import fs from 'fs';
import path from 'path';

import {defaultHttpGet} from '../../http';
import type {HttpGet, HttpResponse} from '../../types';

export function createCachedHttpGet(
  dir: string,
  options: {delayMs?: number; inner?: HttpGet} = {},
): HttpGet & {live: number; cached: number} {
  fs.mkdirSync(dir, {recursive: true});
  const inner = options.inner ?? defaultHttpGet;
  const lastByHost = new Map<string, number>();
  const pending = new Map<string, Promise<HttpResponse>>();
  const get = (async (url, requestOptions) => {
    const file = path.join(
      dir,
      `${crypto.createHash('sha1').update(url).digest('hex')}.json`,
    );
    if (fs.existsSync(file)) {
      get.cached += 1;
      const stored = JSON.parse(fs.readFileSync(file, 'utf8'));
      if (stored.error) {
        throw Object.assign(new Error(stored.error), {kind: stored.kind});
      }
      return stored as HttpResponse;
    }
    const running = pending.get(url);
    if (running) {
      return running;
    }
    const run = (async () => {
      const host = url.split('/')[2] ?? '';
      const wait =
        (lastByHost.get(host) ?? 0) + (options.delayMs ?? 0) - Date.now();
      lastByHost.set(
        host,
        Math.max(Date.now(), lastByHost.get(host) ?? 0) +
          (options.delayMs ?? 0),
      );
      if (wait > 0) {
        await new Promise(resolve => setTimeout(resolve, wait));
      }
      get.live += 1;
      try {
        const response = await inner(url, {
          ...requestOptions,
          signal: undefined,
        });
        fs.writeFileSync(file, JSON.stringify(response));
        return response;
      } catch (error) {
        fs.writeFileSync(
          file,
          JSON.stringify({
            error: (error as Error).message,
            kind: (error as {kind?: string}).kind,
          }),
        );
        throw error;
      } finally {
        pending.delete(url);
      }
    })();
    pending.set(url, run);
    return run;
  }) as HttpGet & {live: number; cached: number};
  get.live = 0;
  get.cached = 0;
  return get;
}
