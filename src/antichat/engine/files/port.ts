/**
 * `FilesPort` over the files engine: what the attachment tray reads.
 *
 * Intake paths, all ending in `engine.add`:
 *   photos / camera  react-native-image-picker (already in the app);
 *   files            @react-native-documents/picker;
 *   paste            `addPastedText` (long text becomes a text attachment);
 *   share-in         `addShared` (payload from a share extension / intent);
 *   scan             not in this build (needs a scanner module).
 */
import {
  Emitter,
  type AttachmentRef,
  type PortError,
} from '../../contracts/common';
import type {
  DraftAttachment,
  FilesPort,
  IngestState,
  PickSource,
} from '../../contracts/files';
import type {FilesEngine} from './engine';
import type {FileRow} from './FilesStore';
import type {FileLimit} from './limits';

/** What another app handed over (share sheet, "Open in", intent). */
export interface SharedPayload {
  files?: Array<{uri: string; name?: string; mimeType?: string}>;
  text?: string;
  url?: string;
}

export interface AntichatFilesPort extends FilesPort {
  /** Limits and notes of a draft, for the tray's small print. */
  limitsOf(attachmentId: string): readonly FileLimit[];
  /**
   * Long pasted text. Returns null when it is short enough to stay in the
   * text field (the caller keeps it there).
   */
  addPastedText(
    conversationId: string | null,
    text: string,
  ): Promise<DraftAttachment | null>;
  /** Files become drafts; text and URL come back for the composer. */
  addShared(
    conversationId: string | null,
    payload: SharedPayload,
  ): Promise<{drafts: DraftAttachment[]; composerText: string}>;
  /** Fields for upstream's send: images for the vision model. */
  sendExtras(conversationId: string | null): Promise<{imageUris?: string[]}>;
  /** The message went out: the tray is empty again. */
  markSent(conversationId: string | null): void;
}

const kindOf = (file: FileRow): AttachmentRef['kind'] =>
  file.kind === 'image'
    ? 'image'
    : file.kind === 'audio'
      ? 'audio'
      : file.name.startsWith('Pasted text')
        ? 'text'
        : 'document';

function stateOf(file: FileRow): IngestState {
  if (file.status === 'processing') {
    return {status: 'processing'};
  }
  if (file.status === 'failed') {
    const blocked = file.data.limits?.find(l => l.severity === 'blocked');
    const error: PortError = {
      code: blocked?.code === 'file_too_large' ? 'context_full' : 'unsupported',
      retryable: false,
      detail: blocked?.code ?? file.data.error,
    };
    return {status: 'failed', error};
  }
  return {
    status: 'ready',
    pageCount: file.pageCount ?? undefined,
    mode:
      file.mode === 'retrieval'
        ? 'retrieval'
        : file.mode === 'vision'
          ? 'vision'
          : file.mode === 'ocr'
            ? 'ocr'
            : 'inline',
  };
}

const NEW_CHAT = '';

export function createFilesPort(engine: FilesEngine): AntichatFilesPort {
  class Port extends Emitter implements AntichatFilesPort {
    private readonly byChat = new Map<string, DraftAttachment[]>();
    private readonly limits = new Map<string, FileLimit[]>();
    private temp = 0;

    constructor() {
      super();
      engine.subscribe(event => {
        if (event.type === 'progress') {
          this.patch(event.fileId, {
            status: 'processing',
            fraction: event.fraction,
          });
        }
      });
    }

    get maxPerMessage(): number {
      return engine.budget().maxFilesPerMessage;
    }

    drafts = (conversationId: string | null): readonly DraftAttachment[] =>
      this.byChat.get(conversationId ?? NEW_CHAT) ?? EMPTY;

    limitsOf = (attachmentId: string): readonly FileLimit[] =>
      this.limits.get(attachmentId) ?? [];

    private set(key: string, drafts: DraftAttachment[]): void {
      this.byChat.set(key, drafts);
      this.emit();
    }

    private patch(id: string, state: IngestState, next?: AttachmentRef): void {
      for (const [key, drafts] of this.byChat) {
        if (drafts.some(draft => draft.attachment.id === id)) {
          this.set(
            key,
            drafts.map(draft =>
              draft.attachment.id === id
                ? {attachment: next ?? draft.attachment, state}
                : draft,
            ),
          );
        }
      }
    }

    add = async (
      conversationId: string | null,
      attachment: AttachmentRef,
    ): Promise<DraftAttachment> => {
      const key = conversationId ?? NEW_CHAT;
      const current = this.byChat.get(key) ?? [];
      if (current.length >= this.maxPerMessage) {
        const refused: DraftAttachment = {
          attachment,
          state: {
            status: 'failed',
            error: {
              code: 'unsupported',
              retryable: false,
              detail: 'too_many_files',
            },
          },
        };
        this.limits.set(attachment.id, [
          {
            code: 'too_many_files',
            severity: 'blocked',
            params: {max: this.maxPerMessage},
          },
        ]);
        return refused;
      }
      // Shown at once under a temporary id; replaced when the row exists.
      const tempId = attachment.id || `draft-${++this.temp}`;
      const shown: AttachmentRef = {...attachment, id: tempId};
      this.set(key, [
        ...current,
        {attachment: shown, state: {status: 'processing'}},
      ]);
      try {
        const {file} = await engine.add({
          uri: attachment.uri,
          name: attachment.name,
          mimeType: attachment.mimeType,
          sizeBytes: attachment.sizeBytes,
          sessionId: conversationId,
          keep: !attachment.uri.includes('/antichat-files/'),
        });
        const ready: DraftAttachment = {
          attachment: {
            ...shown,
            id: file.id,
            uri: file.uri,
            kind: kindOf(file),
          },
          state: stateOf(file),
        };
        this.limits.set(file.id, file.data.limits ?? []);
        this.set(
          key,
          (this.byChat.get(key) ?? []).map(draft =>
            draft.attachment.id === tempId ? ready : draft,
          ),
        );
        return ready;
      } catch (error) {
        const failed: DraftAttachment = {
          attachment: shown,
          state: {
            status: 'failed',
            error: {code: 'failed', retryable: true, detail: String(error)},
          },
        };
        this.patch(tempId, failed.state);
        return failed;
      }
    };

    pick = async (
      conversationId: string | null,
      source: PickSource,
    ): Promise<DraftAttachment[]> => {
      const room = this.maxPerMessage - this.drafts(conversationId).length || 1;
      let picked: Array<Omit<AttachmentRef, 'id'>> = [];
      if (source === 'photos' || source === 'camera') {
        const picker = require('react-native-image-picker');
        const result =
          source === 'camera'
            ? await picker.launchCamera({mediaType: 'photo', quality: 0.9})
            : await picker.launchImageLibrary({
                mediaType: 'photo',
                selectionLimit: room,
                quality: 0.9,
              });
        picked = (result.assets ?? []).map((asset: any) => ({
          kind: 'image' as const,
          name: asset.fileName ?? 'Photo.jpg',
          uri: asset.uri,
          mimeType: asset.type,
          sizeBytes: asset.fileSize,
          width: asset.width,
          height: asset.height,
        }));
      } else if (source === 'files') {
        const documents = require('@react-native-documents/picker');
        try {
          const results = await documents.pick({allowMultiSelection: true});
          const copies = await documents.keepLocalCopy({
            files: results.map((file: any) => ({
              uri: file.uri,
              fileName: file.name ?? 'file',
            })),
            destination: 'cachesDirectory',
          });
          picked = results.map((file: any, index: number) => ({
            kind: 'document' as const,
            name: file.name ?? 'file',
            uri:
              copies[index]?.status === 'success'
                ? copies[index].localUri
                : file.uri,
            mimeType: file.type ?? undefined,
            sizeBytes: file.size ?? undefined,
          }));
        } catch (error) {
          if (documents.isErrorWithCode?.(error)) {
            return [];
          }
          throw error;
        }
      } else {
        // 'scan' needs a scanner module; 'paste' goes through addPastedText.
        return [];
      }
      const out: DraftAttachment[] = [];
      for (const attachment of picked.slice(0, room)) {
        out.push(await this.add(conversationId, {...attachment, id: ''}));
      }
      return out;
    };

    addPastedText = async (
      conversationId: string | null,
      text: string,
    ): Promise<DraftAttachment | null> => {
      if (text.length < engine.budget().pasteThresholdChars) {
        return null;
      }
      const key = conversationId ?? NEW_CHAT;
      const {file} = await engine.addText(text, conversationId);
      const draft: DraftAttachment = {
        attachment: {
          id: file.id,
          kind: 'text',
          name: file.name,
          uri: file.uri,
          mimeType: 'text/plain',
          sizeBytes: text.length,
        },
        state: stateOf(file),
      };
      this.limits.set(file.id, file.data.limits ?? []);
      this.set(key, [...(this.byChat.get(key) ?? []), draft]);
      return draft;
    };

    addShared = async (
      conversationId: string | null,
      payload: SharedPayload,
    ): Promise<{drafts: DraftAttachment[]; composerText: string}> => {
      const drafts: DraftAttachment[] = [];
      for (const file of payload.files ?? []) {
        const name =
          file.name ?? decodeURIComponent(file.uri.split('/').pop() ?? 'file');
        drafts.push(
          await this.add(conversationId, {
            id: '',
            kind: file.mimeType?.startsWith('image/') ? 'image' : 'document',
            name,
            uri: file.uri,
            mimeType: file.mimeType,
          }),
        );
      }
      let composerText = [payload.text, payload.url].filter(Boolean).join('\n');
      if (composerText.length >= engine.budget().pasteThresholdChars) {
        const pasted = await this.addPastedText(conversationId, composerText);
        if (pasted) {
          drafts.push(pasted);
          composerText = '';
        }
      }
      return {drafts, composerText};
    };

    remove = (conversationId: string | null, attachmentId: string): void => {
      const key = conversationId ?? NEW_CHAT;
      this.set(
        key,
        (this.byChat.get(key) ?? []).filter(
          draft => draft.attachment.id !== attachmentId,
        ),
      );
      this.limits.delete(attachmentId);
      engine.remove(attachmentId).catch(() => undefined);
    };

    clear = (conversationId: string | null): void => {
      const key = conversationId ?? NEW_CHAT;
      for (const draft of this.byChat.get(key) ?? []) {
        engine.remove(draft.attachment.id).catch(() => undefined);
      }
      this.set(key, []);
    };

    sendExtras = async (
      conversationId: string | null,
    ): Promise<{imageUris?: string[]}> => {
      const imageUris = await engine.imageUris(conversationId);
      return imageUris.length ? {imageUris} : {};
    };

    markSent = (conversationId: string | null): void => {
      this.set(conversationId ?? NEW_CHAT, []);
    };

    /** Needs a photo-library module (CameraRoll); not in this build. */
    recentPhotos = async (_limit: number): Promise<AttachmentRef[]> => [];
  }
  return new Port();
}

const EMPTY: readonly DraftAttachment[] = Object.freeze([]);
