import {Emitter, type AttachmentRef} from '../common';
import type {DraftAttachment, FilesPort, PickSource} from '../files';

const NEW_CHAT = '\u0000new';

const SAMPLES: Record<PickSource, Omit<AttachmentRef, 'id'>> = {
  photos: {
    kind: 'image',
    name: 'IMG_2041.jpg',
    uri: 'fake://photo/2041',
    mimeType: 'image/jpeg',
    sizeBytes: 2_400_000,
    width: 3024,
    height: 4032,
  },
  camera: {
    kind: 'image',
    name: 'Photo.jpg',
    uri: 'fake://camera/1',
    mimeType: 'image/jpeg',
    sizeBytes: 3_100_000,
    width: 4032,
    height: 3024,
  },
  files: {
    kind: 'document',
    name: 'Rental agreement.pdf',
    uri: 'fake://files/rental.pdf',
    mimeType: 'application/pdf',
    sizeBytes: 480_000,
  },
  scan: {
    kind: 'document',
    name: 'Scan.pdf',
    uri: 'fake://scan/1.pdf',
    mimeType: 'application/pdf',
    sizeBytes: 900_000,
  },
  paste: {
    kind: 'text',
    name: 'Pasted text',
    uri: 'fake://paste/1.txt',
    mimeType: 'text/plain',
    sizeBytes: 14_000,
  },
};

/** Attachments that take a moment to get ready, like real extraction. */
export class FakeFiles extends Emitter implements FilesPort {
  readonly maxPerMessage = 20;
  private readonly byChat = new Map<string, DraftAttachment[]>();
  private nextId = 1;

  constructor(private readonly processMs = 600) {
    super();
  }

  drafts(conversationId: string | null): readonly DraftAttachment[] {
    return this.byChat.get(conversationId ?? NEW_CHAT) ?? EMPTY;
  }

  async pick(
    conversationId: string | null,
    source: PickSource,
  ): Promise<DraftAttachment[]> {
    return [
      await this.add(conversationId, {
        ...SAMPLES[source],
        id: `a${this.nextId++}`,
      }),
    ];
  }

  async add(
    conversationId: string | null,
    attachment: AttachmentRef,
  ): Promise<DraftAttachment> {
    const key = conversationId ?? NEW_CHAT;
    if (this.drafts(conversationId).length >= this.maxPerMessage) {
      throw new Error('Too many attachments');
    }
    const draft: DraftAttachment = {
      attachment,
      state: {status: 'processing', fraction: 0},
    };
    this.byChat.set(key, [...this.drafts(conversationId), draft]);
    this.emit();
    setTimeout(() => {
      this.byChat.set(
        key,
        (this.byChat.get(key) ?? []).map(item =>
          item.attachment.id === attachment.id
            ? {
                ...item,
                state: {
                  status: 'ready',
                  mode: attachment.kind === 'image' ? 'vision' : 'inline',
                  pageCount: attachment.kind === 'document' ? 3 : undefined,
                },
              }
            : item,
        ),
      );
      this.emit();
    }, this.processMs);
    return draft;
  }

  remove(conversationId: string | null, attachmentId: string): void {
    this.byChat.set(
      conversationId ?? NEW_CHAT,
      this.drafts(conversationId).filter(
        draft => draft.attachment.id !== attachmentId,
      ),
    );
    this.emit();
  }

  clear(conversationId: string | null): void {
    this.byChat.delete(conversationId ?? NEW_CHAT);
    this.emit();
  }

  async recentPhotos(limit: number): Promise<AttachmentRef[]> {
    return Array.from({length: Math.min(limit, 4)}, (_, index) => ({
      ...SAMPLES.photos,
      id: `recent${index}`,
      name: `IMG_20${40 - index}.jpg`,
      uri: `fake://photo/20${40 - index}`,
    }));
  }
}

const EMPTY: readonly DraftAttachment[] = Object.freeze([]);
