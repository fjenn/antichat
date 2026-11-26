/**
 * Provider registry behind the D2 seam.
 *
 * With no provider registered `prepareRequest` hands its input back untouched,
 * so a build without AntiChat's engine behaves exactly as upstream PocketPal.
 */
import {createEstimatingCounter, messageText} from '../context/tokenCounter';
import {familyProfile} from './modelFamily';
import type {
  ChatMessage,
  Contribution,
  PrepareRequestInput,
  PreparedRequest,
  RequestContext,
  RequestDraft,
  RequestProvider,
  RuntimeInfo,
  SystemBlock,
  ToolDefinition,
} from './types';

const providers = new Map<string, RequestProvider>();

const DEFAULT_ORDER = 100;
const DEFAULT_N_CTX = 4096;

/** Register (or replace) a provider. Returns the function that removes it. */
export function registerRequestProvider(provider: RequestProvider): () => void {
  providers.set(provider.id, provider);
  return () => {
    if (providers.get(provider.id) === provider) {
      providers.delete(provider.id);
    }
  };
}

export function unregisterRequestProvider(id: string): void {
  providers.delete(id);
}

export function hasRequestProviders(): boolean {
  return providers.size > 0;
}

export function listRequestProviders(): RequestProvider[] {
  return [...providers.values()].sort(
    (a, b) =>
      (a.order ?? DEFAULT_ORDER) - (b.order ?? DEFAULT_ORDER) ||
      a.id.localeCompare(b.id),
  );
}

/** Test helper. */
export function clearRequestProviders(): void {
  providers.clear();
}

const toolName = (tool: ToolDefinition): string => tool.function?.name ?? '';

const byOrder = (a: SystemBlock, b: SystemBlock) =>
  (a.order ?? DEFAULT_ORDER) - (b.order ?? DEFAULT_ORDER);

/**
 * One system message: stable blocks, then what upstream had there (pal prompt
 * and talent fragments), then session blocks. Blocks keep registration order
 * within the same `order`, so the bytes are deterministic.
 */
export function composeSystemText(
  blocks: SystemBlock[],
  upstreamSystem: string,
): string {
  const seen = new Set<string>();
  const unique = blocks.filter(block => {
    if (!block.text.trim() || seen.has(block.id)) {
      return false;
    }
    seen.add(block.id);
    return true;
  });
  const stable = unique.filter(b => b.slot === 'stable').sort(byOrder);
  const session = unique.filter(b => b.slot === 'session').sort(byOrder);
  return [
    ...stable.map(b => b.text.trim()),
    upstreamSystem.trim(),
    ...session.map(b => b.text.trim()),
  ]
    .filter(Boolean)
    .join('\n\n');
}

/** Append turn context to the newest user message without mutating it. */
export function appendTurnContext(
  messages: ChatMessage[],
  lines: string[],
): ChatMessage[] {
  const text = lines
    .map(line => line.trim())
    .filter(Boolean)
    .join('\n');
  if (!text) {
    return messages;
  }
  let index = -1;
  for (let i = messages.length - 1; i >= 0; i--) {
    if (messages[i].role === 'user') {
      index = i;
      break;
    }
  }
  if (index === -1) {
    return messages;
  }
  const target = messages[index];
  const suffix = `\n\n[${text}]`;
  let content: unknown;
  if (typeof target.content === 'string') {
    content = target.content + suffix;
  } else if (Array.isArray(target.content)) {
    let patched = false;
    const parts = [...target.content];
    for (let i = parts.length - 1; i >= 0; i--) {
      const part = parts[i] as {type?: string; text?: string};
      if (part?.type === 'text' && typeof part.text === 'string') {
        parts[i] = {...part, text: part.text + suffix};
        patched = true;
        break;
      }
    }
    if (!patched) {
      parts.unshift({type: 'text', text: suffix.trim()});
    }
    content = parts;
  } else {
    content = suffix.trim();
  }
  const out = [...messages];
  out[index] = {...target, content};
  return out;
}

function resolveRuntime(input: PrepareRequestInput): RuntimeInfo {
  const partial = input.runtime ?? {};
  const family = partial.family ?? 'generic';
  return {
    nCtx: partial.nCtx && partial.nCtx > 0 ? partial.nCtx : DEFAULT_N_CTX,
    family,
    modelName: partial.modelName,
    deviceClass: partial.deviceClass ?? 'B',
    tokenCounter:
      partial.tokenCounter ??
      createEstimatingCounter(familyProfile(family).charsPerToken),
    engine: partial.engine,
    signal: partial.signal,
    now: partial.now ?? new Date(),
    timeZone: partial.timeZone,
    modelDefaultSystemPrompt: partial.modelDefaultSystemPrompt,
  };
}

const newestUserText = (messages: readonly ChatMessage[]): string => {
  for (let i = messages.length - 1; i >= 0; i--) {
    if (messages[i].role === 'user') {
      return messageText(messages[i]).text;
    }
  }
  return '';
};

function mergeParams(
  base: Record<string, unknown>,
  patch: Record<string, unknown> | undefined,
): Record<string, unknown> {
  if (!patch) {
    return base;
  }
  const merged = {...base, ...patch};
  if (base.chat_template_kwargs || patch.chat_template_kwargs) {
    merged.chat_template_kwargs = {
      ...(base.chat_template_kwargs as object | undefined),
      ...(patch.chat_template_kwargs as object | undefined),
    };
  }
  return merged;
}

/**
 * The seam. Collects every provider's contribution, folds system blocks into
 * the single leading system message, appends turn context to the newest user
 * message, merges tools and params, then runs the transforms.
 *
 * A provider that throws is skipped: a broken add-on must never block a send.
 */
export async function prepareRequest(
  input: PrepareRequestInput,
): Promise<PreparedRequest> {
  const baseTools = input.tools ?? [];
  const baseParams = input.params ?? {};
  if (providers.size === 0) {
    return {
      messages: input.messages,
      tools: baseTools,
      params: baseParams,
      meta: {},
      changed: false,
    };
  }

  const runtime = resolveRuntime(input);
  const context: RequestContext = {
    messages: input.messages,
    session: input.session,
    runtime,
    tools: baseTools,
    params: baseParams,
    userText: newestUserText(input.messages),
  };
  const ordered = listRequestProviders();

  const blocks: SystemBlock[] = [];
  const turnContext: string[] = [];
  const addedTools: ToolDefinition[] = [];
  const removed = new Set<string>();
  let paramPatch: Record<string, unknown> = {};
  let meta: Record<string, unknown> = {};

  for (const provider of ordered) {
    if (!provider.contribute) {
      continue;
    }
    let contribution: Contribution | void;
    try {
      contribution = await provider.contribute(context);
    } catch (error) {
      console.warn(`[antichat] provider ${provider.id} failed`, error);
      continue;
    }
    if (!contribution) {
      continue;
    }
    blocks.push(...(contribution.systemBlocks ?? []));
    turnContext.push(...(contribution.turnContext ?? []));
    addedTools.push(...(contribution.tools ?? []));
    contribution.removeTools?.forEach(name => removed.add(name));
    paramPatch = mergeParams(
      paramPatch,
      contribution.params as Record<string, unknown> | undefined,
    );
    if (contribution.meta) {
      meta = {...meta, ...contribution.meta};
    }
  }

  // Tools: request tools first (stable order), then additions, minus removals.
  const tools: ToolDefinition[] = [];
  const names = new Set<string>();
  for (const tool of [...baseTools, ...addedTools]) {
    const name = toolName(tool);
    if (!name || names.has(name) || removed.has(name)) {
      continue;
    }
    names.add(name);
    tools.push(tool);
  }

  // System message.
  const hasSystem = input.messages[0]?.role === 'system';
  let upstreamSystem = hasSystem ? messageText(input.messages[0]).text : '';
  const modelDefault = runtime.modelDefaultSystemPrompt?.trim();
  if (
    modelDefault &&
    blocks.some(block => block.slot === 'stable') &&
    upstreamSystem.trimStart().startsWith(modelDefault)
  ) {
    upstreamSystem = upstreamSystem.trimStart().slice(modelDefault.length);
  }
  const rest = hasSystem ? input.messages.slice(1) : [...input.messages];
  const kept = blocks.filter(
    block => block.when !== 'tools' || tools.length > 0,
  );
  const systemText = kept.length
    ? composeSystemText(kept, upstreamSystem)
    : upstreamSystem;
  let messages: ChatMessage[] = systemText
    ? [{role: 'system', content: systemText}, ...rest]
    : rest;
  messages = appendTurnContext(messages, turnContext);

  let draft: RequestDraft = {
    messages,
    tools,
    params: mergeParams(
      baseParams as Record<string, unknown>,
      paramPatch,
    ) as RequestDraft['params'],
    meta,
  };

  for (const provider of ordered) {
    if (!provider.transform) {
      continue;
    }
    try {
      draft = (await provider.transform(draft, context)) ?? draft;
    } catch (error) {
      console.warn(`[antichat] transform ${provider.id} failed`, error);
    }
  }

  return {...draft, changed: true};
}
