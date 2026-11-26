import type {ModelDevConfig} from '../models/dev/config';

export type EngineDevStep =
  /** Save a memory through the memory port. */
  | {type: 'memory'; text: string}
  /** Send a message through upstream's send path and wait for the reply. */
  | {
      type: 'chat';
      text: string;
      newChat?: boolean;
      /** Files in `Documents/antichat-m5/files/` to attach (M10). */
      attach?: string[];
      /** Attach as pasted text instead of sending it inline. */
      timeoutSec?: number;
    }
  /** Ingest a file without sending (M10): reports mode, pages, timings. */
  | {type: 'ingest'; file: string; scope?: 'chat' | 'new'}
  /** Embed two texts and report their cosine (embedder check). */
  | {type: 'embed'; texts: string[]}
  | {type: 'wait'; ms: number};

export interface EngineDevConfig extends Omit<ModelDevConfig, 'auto'> {
  auto: 'engine';
  steps?: EngineDevStep[];
  /** Also install the embedder (off in the first version). */
  embeddings?: boolean;
  /** Load this catalogue model instead of the class default. */
  model?: string;
}
