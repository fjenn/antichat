/**
 * Request provider for the system prompt, personalisation and thinking.
 */
import {
  getPersonalization,
  type PersonalizationSettings,
} from './personalization';
import {samplingFor} from './modelFamily';
import {buildSystemBlocks, needsClock, timeLine} from './systemPrompt';
import {thinkingBudgetFor, thinkingParams} from './thinking';
import type {Contribution, RequestProvider} from './types';

export const SYSTEM_PROMPT_PROVIDER_ID = 'antichat.system-prompt';

export interface SystemPromptProviderOptions {
  /** Defaults to the saved personalisation settings. */
  personalization?: () => PersonalizationSettings | null;
  /** Knowledge cutoff of the loaded model, when the model catalogue knows it. */
  knowledgeCutoff?: (modelName?: string) => string | undefined;
  /**
   * Use the vendor's sampling settings for the model family instead of the
   * session's. Off by default: M5's model policy decides.
   */
  applyFamilySampling?: boolean;
}

export function createSystemPromptProvider(
  options: SystemPromptProviderOptions = {},
): RequestProvider {
  return {
    id: SYSTEM_PROMPT_PROVIDER_ID,
    order: 10,
    contribute: ({runtime, session, tools, userText}): Contribution => {
      const thinking = !!session.thinking && !session.spoken;
      const contribution: Contribution = {
        systemBlocks: buildSystemBlocks({
          family: runtime.family,
          deviceClass: runtime.deviceClass,
          personalization: (options.personalization ?? getPersonalization)(),
          knowledgeCutoff: options.knowledgeCutoff?.(runtime.modelName),
          // Provider-supplied tools count too: the seam keeps the clause
          // only when the finished request offers a tool.
          hasTools: tools.length > 0 ? true : 'whenOffered',
          now: runtime.now,
          timeZone: runtime.timeZone,
        }),
        params: {
          ...thinkingParams({
            family: runtime.family,
            enabled: thinking,
            budgetTokens: thinkingBudgetFor(runtime.nCtx),
          }),
          ...(options.applyFamilySampling
            ? samplingFor(runtime.family, thinking)
            : {}),
        },
      };
      if (needsClock(userText)) {
        contribution.turnContext = [timeLine(runtime.now)];
      }
      return contribution;
    },
  };
}
