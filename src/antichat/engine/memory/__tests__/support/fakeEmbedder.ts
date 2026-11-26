import {contentStems} from '../../text';
import {
  normalizeVector,
  type EmbedKind,
  type Embedder,
} from '../../embeddings/types';

/**
 * A deterministic stand-in for the embedding model: a hashed bag of word
 * stems, with a few synonym groups folded together so that paraphrases
 * ("has a puppy" / "owns a dog") land close to each other, which keyword
 * search cannot do. Same text → same vector, always.
 */
const SYNONYMS: string[][] = [
  ['dog', 'puppy', 'canine', 'hound', 'beagle'],
  ['vegetarian', 'meatless', 'veggie', 'meat-free'],
  ['car', 'automobile', 'vehicle'],
  ['doctor', 'physician', 'medic'],
  ['home', 'house', 'apartment', 'flat', 'live', 'reside'],
  ['job', 'work', 'career', 'profession', 'employ'],
  ['run', 'jog', 'marathon'],
  ['cook', 'recipe', 'dinner', 'meal', 'food', 'eat'],
  ['own', 'have', 'has'],
];
const CANONICAL = new Map<string, string>();
for (const group of SYNONYMS) {
  for (const word of group) {
    CANONICAL.set(word, group[0]);
  }
}

/* eslint-disable no-bitwise */
function hash(text: string): number {
  let h = 2166136261;
  for (let i = 0; i < text.length; i++) {
    h = Math.imul(h ^ text.charCodeAt(i), 16777619) >>> 0;
  }
  return h;
}

export interface FakeEmbedder extends Embedder {
  calls: Array<{texts: string[]; kind: EmbedKind}>;
}

export function createFakeEmbedder(
  dims: number = 256,
  id: string = 'fake-embedder',
): FakeEmbedder {
  const embedder: FakeEmbedder = {
    id,
    dims,
    calls: [],
    async embed(texts, kind) {
      embedder.calls.push({texts, kind});
      return texts.map(text => {
        const vector = new Float32Array(dims);
        // Unlike keyword search, keep "have"/"has": they are in a group.
        const stems = [
          ...contentStems(text),
          ...text
            .toLowerCase()
            .split(/[^a-z]+/)
            .filter(word => CANONICAL.has(word)),
        ];
        for (const stem of stems) {
          const word = CANONICAL.get(stem) ?? stem;
          if (word === 'user') {
            continue;
          }
          const h = hash(word);
          vector[h % dims] += h & 1024 ? 1 : -1;
          vector[(h >>> 11) % dims] += 0.5;
        }
        return normalizeVector(vector);
      });
    },
  };
  return embedder;
}
