/**
 * Puts M9's engine behind the memory screen and the chat components. Until
 * this is called they run on the contract fake.
 */
import type {MemoryEngine} from '../../engine/memory/engine';
import {createEngineMemoryUi} from './engineMemoryUi';
import {setMemoryUi} from './registry';

export interface MemoryUiDeps {
  /** From `installMemoryEngine` (or `createMemoryEngine` in tests). */
  engine: Pick<MemoryEngine, 'port'>;
}

/** Returns a function that goes back to the fake. */
export function registerMemoryUi(deps: MemoryUiDeps): () => void {
  const memory = createEngineMemoryUi(deps.engine.port);
  setMemoryUi(memory);
  return () => {
    memory.dispose();
    setMemoryUi();
  };
}
