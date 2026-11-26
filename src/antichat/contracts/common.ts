/** Shared shapes of the port contracts. */

export type Unsubscribe = () => void;

/**
 * Every port is observable the same way: read its fields, and subscribe to be
 * told that something changed. Works with `useSyncExternalStore` (see
 * `usePort`) and needs no MobX in the UI.
 */
export interface Observable {
  subscribe(listener: () => void): Unsubscribe;
}

/** A file or photo attached to a message. */
export interface AttachmentRef {
  id: string;
  kind: 'image' | 'document' | 'audio' | 'text';
  name: string;
  /** Local file URI. */
  uri: string;
  mimeType?: string;
  sizeBytes?: number;
  /** Images: pixel size, so a thumbnail can be laid out before it loads. */
  width?: number;
  height?: number;
}

/** Errors the UI words itself; `detail` is for logs only. */
export interface PortError {
  code:
    | 'model_not_loaded'
    | 'out_of_memory'
    | 'context_full'
    | 'offline'
    | 'cancelled'
    | 'unsupported'
    | 'failed';
  retryable: boolean;
  detail?: string;
}

/** Minimal listener set every fake and adapter can reuse. */
export class Emitter implements Observable {
  private readonly listeners = new Set<() => void>();

  subscribe = (listener: () => void): Unsubscribe => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };

  protected emit(): void {
    this.listeners.forEach(listener => listener());
  }
}
