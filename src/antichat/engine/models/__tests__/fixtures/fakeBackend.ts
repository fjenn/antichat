import type {CatalogFile} from '../../catalog/types';
import type {DeviceSnapshot} from '../../device/types';
import type {DownloadTask, LoadRequest, ModelBackend} from '../../engine';
import type {NetworkStatus} from '../../policy/download';

export interface FakeContext {
  modelId: string;
  request: LoadRequest;
}

interface LiveDownload {
  file: CatalogFile;
  onProgress: (bytes: number, rate?: number) => void;
  resolve: () => void;
  reject: (error: Error) => void;
  paused: boolean;
  cancelled: boolean;
}

/**
 * In-memory platform for the engine tests. Downloads complete by themselves
 * unless `manualDownloads` is set, in which case the test drives them.
 */
export class FakeBackend implements ModelBackend<FakeContext> {
  networkStatus: NetworkStatus = {online: true, metered: false};
  freeBytes: number | null = 64 * 1000 ** 3;
  availableBytes: number | undefined;
  manualDownloads = false;
  /** sha256 -> bytes on disk */
  readonly disk = new Map<string, number>();
  readonly verified = new Set<string>();
  /** Files whose content will not match the hash. */
  readonly corrupt = new Set<string>();
  readonly live: LiveDownload[] = [];
  readonly log: string[] = [];
  readonly loadRequests: LoadRequest[] = [];
  readonly released: FakeContext[] = [];
  /** Decide the outcome of one init attempt; default: succeed. */
  onInit: (request: LoadRequest) => Promise<void> | void = () => undefined;
  downloadError: Error | null = null;

  constructor(public snapshot: DeviceSnapshot) {}

  async readDevice(): Promise<DeviceSnapshot> {
    return this.snapshot;
  }

  network(): NetworkStatus {
    return this.networkStatus;
  }

  async freeStorageBytes(): Promise<number | null> {
    return this.freeBytes;
  }

  async availableMemoryBytes(): Promise<number> {
    if (this.availableBytes === undefined) {
      throw new Error('no reading');
    }
    return this.availableBytes;
  }

  async bytesOnDisk(file: CatalogFile): Promise<number> {
    return this.disk.get(file.sha256) ?? 0;
  }

  async isVerified(file: CatalogFile): Promise<boolean> {
    return this.verified.has(file.sha256);
  }

  download(
    file: CatalogFile,
    onProgress: (bytes: number, rate?: number) => void,
  ): DownloadTask {
    this.log.push(`download ${file.path}`);
    let resolve: () => void = () => undefined;
    let reject: (error: Error) => void = () => undefined;
    const done = new Promise<void>((res, rej) => {
      resolve = res;
      reject = rej;
    });
    const entry: LiveDownload = {
      file,
      onProgress,
      resolve,
      reject,
      paused: false,
      cancelled: false,
    };
    this.live.push(entry);
    if (this.downloadError) {
      const error = this.downloadError;
      Promise.resolve().then(() => this.fail(file, error));
    } else if (!this.manualDownloads) {
      Promise.resolve().then(() => {
        this.progress(file, Math.floor(file.sizeBytes / 2));
        this.complete(file);
      });
    }
    return {
      done,
      pause: () => {
        entry.paused = true;
        this.log.push(`pause ${file.path}`);
      },
      resume: () => {
        entry.paused = false;
        this.log.push(`resume ${file.path}`);
      },
      cancel: () => {
        entry.cancelled = true;
        this.log.push(`cancel ${file.path}`);
        this.settle(file).reject(new Error('cancelled'));
      },
    };
  }

  private settle(file: CatalogFile): LiveDownload {
    const index = this.live.findIndex(d => d.file === file);
    if (index < 0) {
      throw new Error(`no live download for ${file.path}`);
    }
    return this.live.splice(index, 1)[0];
  }

  /** The download in flight (manual mode). */
  current(): LiveDownload {
    return this.live[this.live.length - 1];
  }

  progress(file: CatalogFile, bytes: number, rate = 1_000_000): void {
    this.disk.set(file.sha256, bytes);
    this.live.find(d => d.file === file)?.onProgress(bytes, rate);
  }

  complete(file: CatalogFile): void {
    this.disk.set(file.sha256, file.sizeBytes);
    this.settle(file).resolve();
  }

  fail(file: CatalogFile, error: Error): void {
    this.settle(file).reject(error);
  }

  async verify(
    file: CatalogFile,
    onProgress: (fraction: number) => void,
  ): Promise<boolean> {
    this.log.push(`verify ${file.path}`);
    onProgress(0.5);
    onProgress(1);
    if (this.corrupt.has(file.sha256)) {
      return false;
    }
    this.verified.add(file.sha256);
    return true;
  }

  async remove(file: CatalogFile): Promise<void> {
    if (this.disk.has(file.sha256)) {
      this.log.push(`remove ${file.path}`);
    }
    this.disk.delete(file.sha256);
    this.verified.delete(file.sha256);
  }

  /** Put complete, verified files on disk as if installed earlier. */
  install(files: CatalogFile[]): void {
    for (const file of files) {
      this.disk.set(file.sha256, file.sizeBytes);
      this.verified.add(file.sha256);
    }
  }

  async initContext(request: LoadRequest): Promise<FakeContext> {
    this.loadRequests.push(request);
    this.log.push(`init ${request.model.id} ${request.attempt.kind}`);
    await this.onInit(request);
    return {modelId: request.model.id, request};
  }

  async releaseContext(context: FakeContext): Promise<void> {
    this.log.push(`release ${context.modelId}`);
    this.released.push(context);
  }

  async releaseProjector(context: FakeContext): Promise<void> {
    this.log.push(`release-projector ${context.modelId}`);
  }

  async releaseAux(which: string): Promise<void> {
    this.log.push(`release-aux ${which}`);
  }
}

/** Let queued promise callbacks run. */
export const flush = async (turns = 20): Promise<void> => {
  for (let i = 0; i < turns; i++) {
    await Promise.resolve();
  }
};
