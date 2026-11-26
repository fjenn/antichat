/**
 * The model-backed `Embedder`: an embedding GGUF in a second llama.rn
 * context, next to the chat model's.
 *
 * Everything here runs against the small `EmbeddingContext` interface, so
 * the prompt prefixes, the Matryoshka cut and the batching are tested with
 * a scripted context. Only `loadLlamaRnContext` touches llama.rn, and it
 * needs the model file named in `catalog.ts`.
 */
import type {EmbeddingModelSpec} from './catalog';
import {truncateVector, type EmbedKind, type Embedder} from './types';

/** The part of a llama.rn context the embedder uses. */
export interface EmbeddingContext {
  embedding(
    text: string,
    params?: {embd_normalize?: number},
  ): Promise<{embedding: number[]}>;
  release(): Promise<void>;
}

export interface EmbeddingLoadOptions {
  modelPath: string;
  spec: EmbeddingModelSpec;
  /** Run on the GPU. Off by default: the chat model owns the GPU memory. */
  useGpu?: boolean;
  threads?: number;
}

export type EmbeddingContextLoader = (
  options: EmbeddingLoadOptions,
) => Promise<EmbeddingContext>;

/** Characters kept per text: about 3 per token, under the model's window. */
const charLimit = (spec: EmbeddingModelSpec): number => spec.nCtx * 3;

export function withPrefix(
  spec: EmbeddingModelSpec,
  text: string,
  kind: EmbedKind,
): string {
  const prefix = kind === 'query' ? spec.queryPrefix : spec.documentPrefix;
  return prefix + text.replace(/\s+/g, ' ').trim().slice(0, charLimit(spec));
}

export function createLlamaEmbedder(
  spec: EmbeddingModelSpec,
  context: EmbeddingContext,
): Embedder {
  return {
    id: spec.id,
    dims: spec.dims,
    async embed(texts, kind) {
      const out: Float32Array[] = [];
      // One at a time: llama.rn serialises a context's work anyway, and a
      // sequential loop keeps peak memory flat.
      for (const text of texts) {
        const result = await context.embedding(withPrefix(spec, text, kind), {
          embd_normalize: 2,
        });
        if (result.embedding.length < spec.dims) {
          throw new Error(
            `Embedding model returned ${result.embedding.length} dimensions, expected at least ${spec.dims}`,
          );
        }
        out.push(truncateVector(result.embedding, spec.dims));
      }
      return out;
    },
  };
}

/**
 * Opens the embedding model in llama.rn. Settings that matter on a phone:
 *  - `embedding: true` with mean pooling;
 *  - `n_ctx` = the model's window, `n_batch` the same (an embedding must be
 *    computed in one batch);
 *  - CPU by default (`n_gpu_layers: 0`): a 300M encoder embeds a short
 *    memory in tens of milliseconds on CPU, and Metal memory stays with
 *    the chat model;
 *  - `use_mmap` on, `use_mlock` off, so iOS can page the weights out.
 */
export const loadLlamaRnContext: EmbeddingContextLoader = async options => {
  // Required lazily: importing llama.rn at module load would pull native
  // code into every consumer of the memory engine.
  const {initLlama} = require('llama.rn');
  const context = await initLlama({
    model: options.modelPath,
    embedding: true,
    pooling_type: options.spec.pooling,
    n_ctx: options.spec.nCtx,
    n_batch: options.spec.nCtx,
    n_threads: options.threads ?? 4,
    n_gpu_layers: options.useGpu ? 99 : 0,
    use_mmap: true,
    use_mlock: false,
  });
  return {
    embedding: (text, params) => context.embedding(text, params),
    release: () => context.release(),
  };
};
