/**
 * The upstream side of the D2 seam: the one function
 * `src/hooks/useChatSession.ts` calls. It binds `prepareRequest` to the app's
 * stores and writes the result back into the request in place.
 *
 * With no provider registered it returns before touching anything, so the
 * app behaves exactly as upstream. It never throws: on any failure the
 * request goes out as upstream built it.
 */
import {chatSessionStore, modelStore} from '../../../store';
import type {
  ApiCompletionParams,
  CompletionEngine,
} from '../../../utils/completionTypes';
import {
  createEstimatingCounter,
  createLlamaTokenCounter,
  type TokenCounter,
  type TokenisingContext,
} from '../context/tokenCounter';
import {allowedOffline, offlineChats} from '../offline';
import {toolCatalog} from '../tools/catalog';
import {detectModelFamily, familyProfile} from './modelFamily';
import {hasRequestProviders, prepareRequest} from './registry';
import type {
  ChatMessage,
  DeviceClass,
  PreparedRequest,
  SessionInfo,
  ToolDefinition,
} from './types';

export interface SeamExtras {
  spoken?: boolean;
  engine?: CompletionEngine;
  signal?: AbortSignal;
}

/** Facts other milestones know and the seam does not (M5, M6, M2). */
export interface SeamEnvironment {
  deviceClass?: () => DeviceClass | undefined;
  locale?: () => string | undefined;
  countryCode?: () => string | undefined;
  studyMode?: (sessionId?: string) => boolean;
  temporary?: (sessionId?: string) => boolean;
  /**
   * The chat's flags from the conversation store (M3): the source of truth
   * for `temporary` and `projectId`. Null for a chat the store does not know.
   */
  chatFlags?: (
    sessionId: string,
  ) => Promise<{temporary: boolean; projectId: string | null} | null>;
  /**
   * Sampling values the user set by hand (Settings > Advanced). They win over
   * the model's and the providers' choices. Empty when expert mode is off.
   */
  sampling?: () => {temperature?: number};
}

let environment: SeamEnvironment = {};

export function setSeamEnvironment(next: SeamEnvironment): void {
  environment = {...environment, ...next};
}

export interface SentRequest {
  sessionId?: string;
  messages: ChatMessage[];
  prepared: PreparedRequest;
  at: number;
}

let lastRequest: SentRequest | null = null;

/** The most recent request that went through the seam (for post-turn jobs). */
export function getLastSentRequest(): SentRequest | null {
  return lastRequest;
}

const REMOTE_DEFAULT_N_CTX = 32768;
const counters = new WeakMap<object, TokenCounter>();

function resolveTimeZone(): string | undefined {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || undefined;
  } catch {
    return undefined;
  }
}

function resolveLocale(): string | undefined {
  try {
    return (
      environment.locale?.() ??
      Intl.DateTimeFormat().resolvedOptions().locale ??
      undefined
    );
  } catch {
    return undefined;
  }
}

/** Runtime facts read from the stores. Exported for post-turn jobs. */
export function resolveSeamRuntime(extras: SeamExtras = {}) {
  const model = modelStore.activeModel;
  const family = detectModelFamily({
    name: model?.name,
    filename: (model as {filename?: string} | undefined)?.filename,
    id: model?.id,
  });
  const context = modelStore.context as unknown as
    | (TokenisingContext & object)
    | undefined;
  let tokenCounter: TokenCounter;
  if (context && typeof context.tokenize === 'function') {
    tokenCounter =
      counters.get(context) ??
      createLlamaTokenCounter(context, {
        charsPerToken: familyProfile(family).charsPerToken,
      });
    counters.set(context, tokenCounter);
  } else {
    tokenCounter = createEstimatingCounter(familyProfile(family).charsPerToken);
  }
  const nCtx =
    (context ? modelStore.activeContextSettings?.n_ctx : undefined) ??
    (model as {contextLength?: number} | undefined)?.contextLength ??
    (context ? modelStore.contextInitParams?.n_ctx : undefined) ??
    REMOTE_DEFAULT_N_CTX;
  return {
    nCtx,
    family,
    modelName: model?.name,
    deviceClass: environment.deviceClass?.() ?? ('B' as DeviceClass),
    tokenCounter,
    engine: extras.engine,
    signal: extras.signal,
    now: new Date(),
    timeZone: resolveTimeZone(),
    modelDefaultSystemPrompt: model?.chatTemplate?.systemPrompt || undefined,
  };
}

/**
 * Called by `useChatSession` after it has assembled the request. Rewrites
 * `params.messages` / `params.tools` / sampling fields in place and adds the
 * names of provider-contributed tools to `allowedToolNames`.
 */
export async function applyRequestSeam(
  params: ApiCompletionParams,
  allowedToolNames: string[],
  extras: SeamExtras = {},
): Promise<void> {
  if (!hasRequestProviders()) {
    return;
  }
  try {
    const sessionId = chatSessionStore.activeSessionId ?? undefined;
    const locale = resolveLocale();
    const flags = sessionId
      ? await environment.chatFlags?.(sessionId).catch(() => null)
      : null;
    const session: SessionInfo = {
      id: sessionId,
      spoken: !!extras.spoken,
      thinking: !!params.enable_thinking && !extras.spoken,
      studyMode: environment.studyMode?.(sessionId) ?? false,
      temporary:
        flags?.temporary ?? environment.temporary?.(sessionId) ?? false,
      offline: offlineChats.claim(sessionId),
      projectId: flags?.projectId ?? null,
      locale,
      countryCode: environment.countryCode?.(),
    };
    const baseTools = (params.tools as ToolDefinition[] | undefined) ?? [];
    const rest: Partial<ApiCompletionParams> = {...params};
    delete rest.messages;
    delete rest.tools;
    const prepared = await prepareRequest({
      messages: (params.messages ?? []) as ChatMessage[],
      session,
      tools: baseTools,
      params: rest,
      runtime: resolveSeamRuntime(extras),
    });
    if (session.offline) {
      // Last line of defence: whatever a provider or the pal added, nothing
      // that can reach the network or write a memory goes out.
      const kindOf = (name: string) => toolCatalog.get(name)?.kind;
      const kept = prepared.tools.filter(tool =>
        allowedOffline(tool.function?.name ?? '', kindOf),
      );
      if (kept.length !== prepared.tools.length) {
        prepared.tools = kept;
        prepared.changed = true;
      }
      for (let i = allowedToolNames.length - 1; i >= 0; i--) {
        if (!allowedOffline(allowedToolNames[i], kindOf)) {
          allowedToolNames.splice(i, 1);
        }
      }
    }
    const sampling = environment.sampling?.() ?? {};
    if (sampling.temperature !== undefined) {
      prepared.params = {...prepared.params, temperature: sampling.temperature};
      prepared.changed = true;
    }
    if (!prepared.changed || extras.signal?.aborted) {
      return;
    }
    Object.assign(params, prepared.params);
    params.messages = prepared.messages as ApiCompletionParams['messages'];
    if (prepared.tools.length > 0 || baseTools.length > 0) {
      params.tools = prepared.tools.length ? prepared.tools : undefined;
    }
    for (const tool of prepared.tools) {
      const name = tool.function?.name;
      if (name && !allowedToolNames.includes(name)) {
        allowedToolNames.push(name);
      }
    }
    lastRequest = {
      sessionId,
      messages: prepared.messages,
      prepared,
      at: Date.now(),
    };
  } catch (error) {
    console.warn('[antichat] request seam failed; sending as upstream', error);
  }
}
