/**
 * The embedding models the engine knows how to drive.
 *
 * NO MODEL FILE IS SHIPPED OR DOWNLOADED YET. To switch semantic retrieval
 * on, the model lane (M5 catalogue / M10 files) has to add exactly one
 * file to the phone's models directory and to its catalogue:
 *
 *   embeddinggemma-300M-Q8_0.gguf   (repo unsloth/embeddinggemma-300m-GGUF,
 *   about 329 MB, Gemma licence)
 *
 * and pass its path to `createEmbeddingService`. This is the "known-good
 * fallback" of research 05b §4. The first choice there, EmbeddingGemma 2
 * Q8 (Apache-2.0, 310 MB), is listed below as unverified: whether it loads
 * in llama.rn 0.13 is open question E10, and its GGUF file name has to be
 * confirmed when it is tested. Both use the same prompt format and the
 * same 256-dimension Matryoshka cut, so nothing above this file changes.
 */
export interface EmbeddingModelSpec {
  /** Stored with every vector. Change it and every vector is re-made. */
  id: string;
  filename: string;
  /** Where the file comes from (for the catalogue; never fetched here). */
  source: string;
  sizeBytes: number;
  /** Rough resident memory while loaded (weights + context), bytes. */
  ramBytes: number;
  nativeDims: number;
  /** Dimensions kept (Matryoshka cut). */
  dims: number;
  /** Tokens the model reads per text. */
  nCtx: number;
  /** llama.cpp pooling type. */
  pooling: 'mean' | 'cls';
  queryPrefix: string;
  documentPrefix: string;
  /** False until someone has loaded it in llama.rn on a phone. */
  verified: boolean;
}

const MB = 1024 * 1024;

export const EMBEDDING_GEMMA_300M: EmbeddingModelSpec = {
  id: 'embeddinggemma-300m-q8@256',
  filename: 'embeddinggemma-300M-Q8_0.gguf',
  source: 'https://huggingface.co/unsloth/embeddinggemma-300m-GGUF',
  sizeBytes: 329 * MB,
  ramBytes: 360 * MB,
  nativeDims: 768,
  dims: 256,
  nCtx: 2048,
  pooling: 'mean',
  queryPrefix: 'task: search result | query: ',
  documentPrefix: 'title: none | text: ',
  verified: false,
};

export const EMBEDDING_GEMMA_2: EmbeddingModelSpec = {
  ...EMBEDDING_GEMMA_300M,
  id: 'embeddinggemma-2-q8@256',
  filename: 'embeddinggemma-2-Q8_0.gguf',
  source: 'research 05b §4; file name to be confirmed (E10)',
  sizeBytes: 310 * MB,
  ramBytes: 340 * MB,
  nCtx: 8192,
  verified: false,
};

/** English-only, tiny: the option for 4 GB phones if E10 allows one at all. */
export const MINILM_L6: EmbeddingModelSpec = {
  id: 'all-minilm-l6-v2-q8',
  filename: 'all-MiniLM-L6-v2-Q8_0.gguf',
  source: 'research 05b §4 (what Off Grid bundles)',
  sizeBytes: 25 * MB,
  ramBytes: 60 * MB,
  nativeDims: 384,
  dims: 384,
  nCtx: 256,
  pooling: 'mean',
  queryPrefix: '',
  documentPrefix: '',
  verified: false,
};

export const DEFAULT_EMBEDDING_MODEL = EMBEDDING_GEMMA_300M;
