/**
 * Export and import of chats in ChatGPT's export format, for Data controls.
 *
 * The format work is M3's (`engine/store`); this file is the phone side: a
 * file picker, a temporary file, the share sheet. The pieces that touch
 * native modules are injected so the flow has tests.
 */
import type {ImportResult} from '../../../engine/store/types';
import {base64ToBytes, bytesToBase64} from './base64';

/** The part of M3's conversation adapter this needs. */
export interface ArchiveStore {
  exportConversations(): Promise<unknown[]>;
  exportArchive(): Promise<Uint8Array>;
  importArchive(bytes: Uint8Array): Promise<ImportResult>;
}

export interface TransferDevice {
  /** Writes base64 to a file in the cache folder; resolves its path. */
  writeTemp(fileName: string, base64: string): Promise<string>;
  /** Opens the share sheet for a file. */
  share(path: string, mimeType: string): Promise<void>;
  /** Lets the user pick a file; resolves its base64, or null when cancelled. */
  pickFile(): Promise<{name: string; base64: string} | null>;
}

export type ExportOutcome =
  | {kind: 'shared'; count: number; path: string}
  | {kind: 'empty'};

export type ImportOutcome =
  | {kind: 'cancelled'}
  | {kind: 'imported'; count: number; skipped: number; failed: number};

export const exportFileName = (now = new Date()): string =>
  `antichat-chats-${now.toISOString().slice(0, 10)}.zip`;

export async function exportChats(
  store: ArchiveStore,
  device: TransferDevice,
  now = new Date(),
): Promise<ExportOutcome> {
  const conversations = await store.exportConversations();
  if (conversations.length === 0) {
    return {kind: 'empty'};
  }
  const bytes = await store.exportArchive();
  const path = await device.writeTemp(
    exportFileName(now),
    bytesToBase64(bytes),
  );
  await device.share(path, 'application/zip');
  return {kind: 'shared', count: conversations.length, path};
}

export async function importChats(
  store: ArchiveStore,
  device: TransferDevice,
): Promise<ImportOutcome> {
  const file = await device.pickFile();
  if (!file) {
    return {kind: 'cancelled'};
  }
  const result = await store.importArchive(base64ToBytes(file.base64));
  return {
    kind: 'imported',
    count: result.imported.length,
    skipped: result.skipped,
    failed: result.failed,
  };
}

/** The phone: file system, share sheet, document picker. */
export function phoneTransferDevice(): TransferDevice {
  const RNFS = require('@dr.pogodin/react-native-fs');
  return {
    async writeTemp(fileName, base64) {
      const path = `${RNFS.CachesDirectoryPath}/${fileName}`;
      await RNFS.writeFile(path, base64, 'base64');
      return path;
    },
    async share(path, mimeType) {
      const Share = require('react-native-share').default;
      await Share.open({
        url: `file://${path}`,
        type: mimeType,
        failOnCancel: false,
      });
    },
    async pickFile() {
      const picker = require('@react-native-documents/picker');
      let picked: Array<{uri: string; name: string | null}>;
      try {
        picked = await picker.pick({type: [picker.types.allFiles]});
      } catch (error) {
        if (
          picker.isErrorWithCode(error) &&
          (error as {code?: string}).code ===
            picker.errorCodes.OPERATION_CANCELED
        ) {
          return null;
        }
        throw error;
      }
      const file = picked[0];
      if (!file) {
        return null;
      }
      const name = file.name ?? 'export';
      // A copy in the cache folder can be read on both platforms.
      const [copy] = await picker.keepLocalCopy({
        files: [{uri: file.uri, fileName: name}],
        destination: 'cachesDirectory',
      });
      const uri: string = copy?.status === 'success' ? copy.localUri : file.uri;
      const path = decodeURIComponent(uri.replace(/^file:\/\//, ''));
      const base64 = await RNFS.readFile(path, 'base64');
      return {name, base64};
    },
  };
}

/** M3's store, opened on first use. */
export function phoneArchiveStore(): ArchiveStore {
  const {conversationAdapter} = require('../../../adapters/conversation');
  const adapter = conversationAdapter();
  return {
    exportConversations: () => adapter.exportConversations(),
    exportArchive: () => adapter.exportArchive(),
    importArchive: (bytes: Uint8Array) => adapter.importArchive(bytes),
  };
}
