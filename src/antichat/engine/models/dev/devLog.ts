import * as RNFS from '@dr.pogodin/react-native-fs';

import {DEV_DIR} from './config';

/**
 * Append-only event log and a status file for unattended runs:
 * `Documents/antichat-m5/events.log` (one JSON object per line) and
 * `status.json` (rewritten on every change). The host script polls them.
 */
export class DevLog {
  readonly lines: string[] = [];
  private queue: Promise<unknown> = Promise.resolve();
  private readonly listeners = new Set<() => void>();
  private ready: Promise<unknown>;

  constructor(private readonly name = 'events.log') {
    this.ready = RNFS.mkdir(DEV_DIR).catch(() => undefined);
  }

  event(type: string, data: Record<string, unknown> = {}): void {
    const entry = {t: Date.now(), type, ...data};
    const line = JSON.stringify(entry);
    this.lines.push(line);
    if (this.lines.length > 400) {
      this.lines.splice(0, this.lines.length - 400);
    }
    this.enqueue(() => RNFS.appendFile(`${DEV_DIR}/${this.name}`, line + '\n'));
    this.listeners.forEach(listener => listener());
  }

  status(data: Record<string, unknown>): void {
    const text = JSON.stringify({t: Date.now(), ...data});
    this.enqueue(() => RNFS.writeFile(`${DEV_DIR}/status.json`, text, 'utf8'));
  }

  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  private enqueue(work: () => Promise<unknown>): void {
    this.queue = this.queue
      .then(() => this.ready)
      .then(work)
      .catch(() => undefined);
  }
}
