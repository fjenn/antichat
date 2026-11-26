/** Loads the speech fixtures (Node only: Jest and the host harness). */
import fs from 'fs';
import path from 'path';

import {wavToSpeechPcm} from '../audio/wav';

export interface Fixture {
  id: string;
  file: string;
  voice: string;
  lang: string;
  kind: 'utterance' | 'bargein' | 'tts' | 'long' | 'noise';
  noiseSnrDb?: number;
  text: string;
}

export const FIXTURE_DIR = path.join(__dirname, 'fixtures');

export const fixtures = (): Fixture[] =>
  JSON.parse(fs.readFileSync(path.join(FIXTURE_DIR, 'manifest.json'), 'utf8'));

export const fixture = (id: string): Fixture => {
  const found = fixtures().find(f => f.id === id);
  if (!found) {
    throw new Error(`no fixture ${id}`);
  }
  return found;
};

const cache = new Map<string, Int16Array>();

export function fixturePcm(id: string): Int16Array {
  let pcm = cache.get(id);
  if (!pcm) {
    pcm = wavToSpeechPcm(
      new Uint8Array(fs.readFileSync(path.join(FIXTURE_DIR, fixture(id).file))),
    );
    cache.set(id, pcm);
  }
  return pcm;
}
