/**
 * The seam between memory / file retrieval and an embedding model.
 *
 * Everything above this interface (vector storage, hybrid ranking, dedupe
 * by cosine) is implemented and tested with a deterministic fake. The real
 * implementation is `LlamaEmbedder` (a second llama.rn context); it needs
 * the GGUF named in `catalog.ts`, which is not shipped yet.
 */
export type EmbedKind = 'query' | 'document';

export interface Embedder {
  /** Stored with every vector; vectors of another id are never compared. */
  readonly id: string;
  readonly dims: number;
  /** One unit-length vector per text, in order. */
  embed(texts: string[], kind: EmbedKind): Promise<Float32Array[]>;
}

/** What memory code asks for; null when no embedding model may run. */
export type EmbedderProvider = () => Promise<Embedder | null>;

/** L2-normalise in place and return the vector. */
export function normalizeVector(vector: Float32Array): Float32Array {
  let sum = 0;
  for (let i = 0; i < vector.length; i++) {
    sum += vector[i] * vector[i];
  }
  const norm = Math.sqrt(sum);
  if (norm > 0) {
    for (let i = 0; i < vector.length; i++) {
      vector[i] /= norm;
    }
  }
  return vector;
}

/**
 * Matryoshka truncation: keep the first `dims` values and renormalise.
 * EmbeddingGemma is trained for 768 → 512 / 256 / 128.
 */
export function truncateVector(
  values: ArrayLike<number>,
  dims: number,
): Float32Array {
  const out = new Float32Array(Math.min(dims, values.length));
  for (let i = 0; i < out.length; i++) {
    out[i] = values[i];
  }
  return normalizeVector(out);
}
