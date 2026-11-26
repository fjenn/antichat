/**
 * FilesPort: picking attachments and getting them ready for the model. M10
 * implements it; the attachment tray reads it.
 */
import type {AttachmentRef, Observable, PortError} from './common';

export type PickSource = 'photos' | 'camera' | 'files' | 'scan' | 'paste';

export type IngestState =
  /** Text is being extracted or the file is being indexed. */
  | {status: 'processing'; fraction?: number}
  | {
      status: 'ready';
      pageCount?: number;
      mode: 'inline' | 'retrieval' | 'vision' | 'ocr';
    }
  | {status: 'failed'; error: PortError};

export interface DraftAttachment {
  attachment: AttachmentRef;
  state: IngestState;
}

export interface FilesPort extends Observable {
  /** Attachments in the composer of a chat (null = the new chat). */
  drafts(conversationId: string | null): readonly DraftAttachment[];
  /** Opens the system picker; resolves with what was added (empty if cancelled). */
  pick(
    conversationId: string | null,
    source: PickSource,
  ): Promise<DraftAttachment[]>;
  /** Adds a file the app already has (share sheet, paste). */
  add(
    conversationId: string | null,
    attachment: AttachmentRef,
  ): Promise<DraftAttachment>;
  remove(conversationId: string | null, attachmentId: string): void;
  clear(conversationId: string | null): void;
  /** The newest photos, for the quick row over the + button. */
  recentPhotos(limit: number): Promise<AttachmentRef[]>;
  /** Most attachments one message may carry. */
  readonly maxPerMessage: number;
}
