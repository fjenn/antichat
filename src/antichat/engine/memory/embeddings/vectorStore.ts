/**
 * Vectors in antichat.db's `vectors` table: plain little-endian float32
 * BLOBs, one per (owner, model).
 *
 * Nearest-neighbour search uses sqlite-vec's `vec_distance_cosine` when the
 * extension is loaded (op-sqlite is built with `sqliteVec: true`) and a
 * JavaScript scan otherwise (Jest, or a build without the extension). Both
 * are brute force; at a phone's scale (hundreds of memories, tens of
 * thousands of chunks) that is a few milliseconds.
 */
import type {Db, SqlValue} from '../../store/driver';
import {cosineSimilarity} from '../rankFusion';

export type VectorOwner = 'memory' | 'chunk' | 'digest';

export interface VectorHit {
  ownerId: string;
  /** Cosine similarity, 1 = same direction. */
  similarity: number;
}

/** BLOB parameter. */
export function toBlob(vector: Float32Array): SqlValue {
  const bytes = new Uint8Array(
    vector.buffer.slice(
      vector.byteOffset,
      vector.byteOffset + vector.byteLength,
    ),
  );
  return bytes;
}

/** op-sqlite returns an ArrayBuffer, Node's SQLite a Uint8Array. */
export function fromBlob(blob: unknown): Float32Array {
  // Not `instanceof`: the buffer may come from another JS realm.
  if (Object.prototype.toString.call(blob) === '[object ArrayBuffer]') {
    return new Float32Array((blob as ArrayBuffer).slice(0));
  }
  if (ArrayBuffer.isView(blob)) {
    const view = blob as ArrayBufferView;
    return new Float32Array(
      view.buffer.slice(view.byteOffset, view.byteOffset + view.byteLength),
    );
  }
  return new Float32Array(0);
}

export class VectorStore {
  private sqliteVec: boolean | null = null;

  constructor(
    private readonly db: Db,
    private readonly options: {forceJs?: boolean} = {},
  ) {}

  /** True when sqlite-vec's functions are available on this connection. */
  async hasSqliteVec(): Promise<boolean> {
    if (this.options.forceJs) {
      return false;
    }
    if (this.sqliteVec === null) {
      try {
        await this.db.get('SELECT vec_version() AS v');
        this.sqliteVec = true;
      } catch {
        this.sqliteVec = false;
      }
    }
    return this.sqliteVec;
  }

  /** Stores (or replaces) the vector of one owner for one model. */
  async save(
    ownerKind: VectorOwner,
    ownerId: string,
    model: string,
    vector: Float32Array,
  ): Promise<void> {
    await this.db.transaction(async () => {
      await this.db.run(
        'DELETE FROM vectors WHERE owner_kind = ? AND owner_id = ? AND model = ?',
        [ownerKind, ownerId, model],
      );
      await this.db.run(
        `INSERT INTO vectors (owner_kind, owner_id, model, dims, embedding)
         VALUES (?, ?, ?, ?, ?)`,
        [ownerKind, ownerId, model, vector.length, toBlob(vector)],
      );
    });
  }

  async delete(ownerKind: VectorOwner, ownerIds: string[]): Promise<void> {
    for (const id of ownerIds) {
      await this.db.run(
        'DELETE FROM vectors WHERE owner_kind = ? AND owner_id = ?',
        [ownerKind, id],
      );
    }
  }

  /** Drops vectors written by any other model (after a model change). */
  async deleteOtherModels(
    ownerKind: VectorOwner,
    model: string,
  ): Promise<void> {
    await this.db.run(
      'DELETE FROM vectors WHERE owner_kind = ? AND model <> ?',
      [ownerKind, model],
    );
  }

  async load(
    ownerKind: VectorOwner,
    ownerIds: string[],
    model: string,
  ): Promise<Map<string, Float32Array>> {
    const out = new Map<string, Float32Array>();
    for (let i = 0; i < ownerIds.length; i += 400) {
      const batch = ownerIds.slice(i, i + 400);
      const rows = await this.db.all(
        `SELECT owner_id, embedding FROM vectors
         WHERE owner_kind = ? AND model = ?
           AND owner_id IN (${batch.map(() => '?').join(', ')})`,
        [ownerKind, model, ...batch],
      );
      for (const row of rows) {
        out.set(row.owner_id, fromBlob(row.embedding));
      }
    }
    return out;
  }

  /** Owners among `ownerIds` that have no vector for `model` yet. */
  async missing(
    ownerKind: VectorOwner,
    ownerIds: string[],
    model: string,
  ): Promise<string[]> {
    const have = await this.load(ownerKind, ownerIds, model);
    return ownerIds.filter(id => !have.has(id));
  }

  /**
   * The owners closest to `query`, best first. `among` narrows the search
   * to those owners (a scope filter the caller has already applied).
   */
  async nearest(
    ownerKind: VectorOwner,
    query: Float32Array,
    model: string,
    options: {limit?: number; among?: string[]; minSimilarity?: number} = {},
  ): Promise<VectorHit[]> {
    const limit = options.limit ?? 8;
    const floor = options.minSimilarity ?? -1;
    const among = options.among ? new Set(options.among) : null;
    if (among && among.size === 0) {
      return [];
    }
    let hits: VectorHit[];
    if (await this.hasSqliteVec()) {
      const rows = await this.db.all(
        `SELECT owner_id, 1 - vec_distance_cosine(embedding, ?) AS similarity
         FROM vectors
         WHERE owner_kind = ? AND model = ? AND dims = ?
         ORDER BY similarity DESC LIMIT ?`,
        [toBlob(query), ownerKind, model, query.length, among ? 5000 : limit],
      );
      hits = rows.map(row => ({
        ownerId: row.owner_id as string,
        similarity: row.similarity as number,
      }));
    } else {
      const rows = await this.db.all(
        `SELECT owner_id, embedding FROM vectors
         WHERE owner_kind = ? AND model = ? AND dims = ?`,
        [ownerKind, model, query.length],
      );
      hits = rows
        .map(row => ({
          ownerId: row.owner_id as string,
          similarity: cosineSimilarity(query, fromBlob(row.embedding)),
        }))
        .sort((a, b) => b.similarity - a.similarity);
    }
    return hits
      .filter(
        hit => hit.similarity >= floor && (!among || among.has(hit.ownerId)),
      )
      .slice(0, limit);
  }
}
