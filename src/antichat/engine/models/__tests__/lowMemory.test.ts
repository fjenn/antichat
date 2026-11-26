import {bundledCatalog} from '../catalog/bundledCatalog';
import {
  DEMOTION_WINDOW_MS,
  LowMemoryContext,
  reactToLowMemory,
} from '../policy/lowMemory';

const NOW = 1_000_000_000;
const context = (over: Partial<LowMemoryContext> = {}): LowMemoryContext => ({
  level: 'warning',
  loadedModelId: 'gemma-4-e4b-qat',
  projectorLoaded: true,
  generating: false,
  aux: [],
  recentReleases: [],
  now: NOW,
  ...over,
});
const react = (over: Partial<LowMemoryContext> = {}) =>
  reactToLowMemory(context(over), bundledCatalog);

describe('low-memory reaction', () => {
  it('gives up helper models first, in a fixed order', () => {
    expect(react({aux: ['embeddings', 'imageGeneration', 'voice']})).toEqual([
      {type: 'release_aux', which: 'imageGeneration'},
      {type: 'release_aux', which: 'voice'},
      {type: 'release_aux', which: 'embeddings'},
    ]);
  });

  it('on a warning with no helpers, gives up the projector', () => {
    expect(react()).toEqual([{type: 'release_projector'}]);
  });

  it('on a warning never touches the chat model or an answer in progress', () => {
    expect(react({generating: true})).toEqual([]);
    expect(react({projectorLoaded: false})).toEqual([]);
  });

  it('on a critical event releases the chat model', () => {
    expect(react({level: 'critical', aux: ['embeddings']})).toEqual([
      {type: 'release_aux', which: 'embeddings'},
      {type: 'release_projector'},
      {type: 'release_model', when: 'now'},
    ]);
  });

  it('lets the current answer finish first', () => {
    expect(
      react({level: 'critical', generating: true, projectorLoaded: false}),
    ).toEqual([{type: 'release_model', when: 'after_generation'}]);
  });

  it('switches to the smaller model on the second forced release', () => {
    const actions = react({
      level: 'critical',
      projectorLoaded: false,
      recentReleases: [NOW - 60_000],
    });
    expect(actions).toEqual([
      {type: 'release_model', when: 'now'},
      {
        type: 'demote',
        from: 'gemma-4-e4b-qat',
        to: 'gemma-4-e2b-qat',
        notice: 'low_memory_switched',
      },
    ]);
  });

  it('forgets releases older than the window', () => {
    const actions = react({
      level: 'critical',
      projectorLoaded: false,
      recentReleases: [NOW - DEMOTION_WINDOW_MS - 1],
    });
    expect(actions).toEqual([{type: 'release_model', when: 'now'}]);
  });

  it('cannot go below the smallest model', () => {
    const actions = react({
      level: 'critical',
      loadedModelId: 'lfm3-1.7b',
      projectorLoaded: false,
      recentReleases: [NOW - 1],
    });
    expect(actions).toEqual([{type: 'release_model', when: 'now'}]);
  });

  it('only frees helpers when no chat model is loaded', () => {
    expect(
      react({level: 'critical', loadedModelId: null, aux: ['voice']}),
    ).toEqual([{type: 'release_aux', which: 'voice'}]);
  });
});
