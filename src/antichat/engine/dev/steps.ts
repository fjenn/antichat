/**
 * The dev-run steps that are not a chat message.
 */
import type {InstalledEngine} from '../install';
import {cosineSimilarity} from '../memory/rankFusion';
import type {DevLog} from '../models/dev/devLog';

import type {EngineDevStep} from './types';

const sleep = (ms: number) =>
  new Promise<void>(resolve => setTimeout(resolve, ms));

export const runDevStep = {
  /** Message fields for attached files. Filled in by the files engine. */
  async attachments(
    _files: string[],
    _log: DevLog,
  ): Promise<Record<string, unknown>> {
    return {};
  },

  async other(
    step: Exclude<EngineDevStep, {type: 'chat'}>,
    engine: InstalledEngine,
    _log: DevLog,
  ): Promise<unknown> {
    switch (step.type) {
      case 'wait':
        await sleep(step.ms);
        return {};
      case 'memory': {
        const saved = await engine.memory.port.add(step.text);
        return {saved};
      }
      case 'embed': {
        const fileReady = await engine.embedding.ensureFile();
        const started = Date.now();
        const vectors = await engine.embedding.service.use('index', embedder =>
          embedder.embed(step.texts, 'document'),
        );
        return {
          fileReady,
          fileState: engine.embedding.fileState(),
          unavailable: engine.embedding.service.lastUnavailable,
          ms: Date.now() - started,
          dims: vectors?.[0]?.length ?? null,
          cosineToFirst:
            vectors?.map(vector => cosineSimilarity(vectors[0], vector)) ??
            null,
        };
      }
      default:
        throw new Error(`step "${step.type}" is not supported yet`);
    }
  },
};
