/**
 * Storage figures for Settings > Storage: what AntiChat's models and chats
 * take, and what is free on the phone.
 */
import type {ModelView} from '../../contracts';
import {isInstalled} from './naming';

export interface StorageProbe {
  freeBytes(): Promise<number>;
  totalBytes(): Promise<number>;
  /** Size of the chat databases and attached files. */
  chatBytes(): Promise<number>;
  voiceBytes(): Promise<number>;
  imageBytes(): Promise<number>;
}

export interface StorageBreakdown {
  models: number;
  voices: number;
  images: number;
  chats: number;
  free: number;
  total: number;
  /** Everything on the phone that is not AntiChat's or free. */
  other: number;
}

/** Bytes a model occupies: whole when installed, partial while downloading. */
export function bytesOnPhone(model: ModelView): number {
  if (isInstalled(model) || model.state.status === 'verifying') {
    return model.downloadBytes;
  }
  if (model.state.status === 'downloading') {
    return model.state.progress.receivedBytes;
  }
  return 0;
}

export async function storageBreakdown(
  models: readonly ModelView[],
  probe: StorageProbe,
): Promise<StorageBreakdown> {
  const safe = (read: () => Promise<number>) => read().catch(() => 0);
  const [free, total, chats, voices, images] = await Promise.all([
    safe(probe.freeBytes),
    safe(probe.totalBytes),
    safe(probe.chatBytes),
    safe(probe.voiceBytes),
    safe(probe.imageBytes),
  ]);
  const modelBytes = models.reduce(
    (sum, model) => sum + bytesOnPhone(model),
    0,
  );
  const ours = modelBytes + chats + voices + images;
  // A scripted backend's models take no real space: never show less than fits.
  const capacity = Math.max(total, free + ours);
  return {
    models: modelBytes,
    voices,
    images,
    chats,
    free,
    total: capacity,
    other: Math.max(0, capacity - free - ours),
  };
}

/** Under this much free space the screen says so. */
export const LOW_STORAGE_BYTES = 2_000_000_000;

const DATABASE_FILE = /\.(db|sqlite3?)(-wal|-shm|-journal)?$/i;

/** The phone itself. */
export function phoneStorageProbe(): StorageProbe {
  const DeviceInfo = require('react-native-device-info').default;
  const RNFS = require('@dr.pogodin/react-native-fs');
  const sizeOf = async (dir: string, match?: RegExp): Promise<number> => {
    try {
      const entries: Array<{name: string; size: number; isFile(): boolean}> =
        await RNFS.readDir(dir);
      return entries
        .filter(entry => entry.isFile() && (!match || match.test(entry.name)))
        .reduce((sum, entry) => sum + Number(entry.size), 0);
    } catch {
      return 0;
    }
  };
  return {
    freeBytes: () => DeviceInfo.getFreeDiskStorage(),
    totalBytes: () => DeviceInfo.getTotalDiskCapacity(),
    chatBytes: async () => {
      const dirs = [
        RNFS.DocumentDirectoryPath,
        RNFS.LibraryDirectoryPath,
        `${RNFS.DocumentDirectoryPath}/../databases`,
      ].filter(Boolean);
      const sizes = await Promise.all(
        dirs.map(dir => sizeOf(dir, DATABASE_FILE)),
      );
      return sizes.reduce((sum, size) => sum + size, 0);
    },
    // Filled in by the voice (M11) and image (M12) milestones.
    voiceBytes: async () => 0,
    imageBytes: async () => 0,
  };
}
