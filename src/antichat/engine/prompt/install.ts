/**
 * One call that switches the prompt and context engine on. Until it is
 * called no provider is registered and the app behaves as upstream.
 */
import {
  createContextProvider,
  type ContextProviderOptions,
} from '../context/provider';
import {
  createPersistentContextStateStore,
  setContextStateStore,
} from '../context/summaryStore';
import {createSkillsProvider} from '../skills/provider';
import {loadPersonalization} from './personalization';
import {installPostTurnHooks, type PostTurnHookOptions} from './postTurn';
import {
  createSystemPromptProvider,
  type SystemPromptProviderOptions,
} from './provider';
import {registerRequestProvider} from './registry';
import {setSeamEnvironment, type SeamEnvironment} from './seam';

export interface PromptEngineOptions {
  systemPrompt?: SystemPromptProviderOptions;
  context?: ContextProviderOptions;
  postTurn?: PostTurnHookOptions | false;
  environment?: SeamEnvironment;
  /** Keep summaries in AsyncStorage (default true). */
  persistSummaries?: boolean;
}

/** Install the engine. Returns the function that removes it again. */
export function installPromptEngine(
  options: PromptEngineOptions = {},
): () => void {
  if (options.environment) {
    setSeamEnvironment(options.environment);
  }
  if (options.persistSummaries !== false) {
    setContextStateStore(createPersistentContextStateStore());
  }
  loadPersonalization().catch(() => {});
  const removers = [
    registerRequestProvider(createSystemPromptProvider(options.systemPrompt)),
    registerRequestProvider(createSkillsProvider()),
    registerRequestProvider(createContextProvider(options.context)),
  ];
  if (options.postTurn !== false) {
    removers.push(installPostTurnHooks(options.postTurn ?? {}));
  }
  return () => removers.forEach(remove => remove());
}
