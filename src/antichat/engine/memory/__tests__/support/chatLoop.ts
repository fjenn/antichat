/**
 * One chat turn through the real send pipeline, for the real-model checks:
 * `prepareRequest` (every registered provider) → upstream's `runAgent`
 * (tool calls executed by the registered engines) → final reply. Only the
 * React hook and the MobX stores around it are left out.
 */
import {runAgent} from '../../../../../services/agent';
import type {TalentEngine} from '../../../../../services/talents/types';
import type {
  ApiCompletionParams,
  CompletionEngine,
} from '../../../../../utils/completionTypes';
import type {TokenCounter} from '../../../context/tokenCounter';
import type {ModelFamily} from '../../../prompt/modelFamily';
import {prepareRequest} from '../../../prompt/registry';
import type {
  ChatMessage,
  PreparedRequest,
  SessionInfo,
} from '../../../prompt/types';

export interface TurnInput {
  engine: CompletionEngine;
  family: ModelFamily;
  nCtx: number;
  history: ChatMessage[];
  userText: string;
  session: SessionInfo;
  tools: TalentEngine[];
  now: Date;
  counter?: TokenCounter;
  maxTokens?: number;
  temperature?: number;
}

export interface TurnOutput {
  reply: string;
  toolCalls: Array<{name: string; args: unknown; result: string}>;
  prepared: PreparedRequest;
  /** History to pass to the next turn. */
  history: ChatMessage[];
}

export async function sendTurn(input: TurnInput): Promise<TurnOutput> {
  const messages: ChatMessage[] = [
    ...input.history,
    {role: 'user', content: input.userText},
  ];
  const prepared = await prepareRequest({
    messages,
    session: input.session,
    tools: [],
    params: {},
    runtime: {
      nCtx: input.nCtx,
      family: input.family,
      deviceClass: input.nCtx < 6000 ? 'A' : 'C',
      engine: input.engine,
      tokenCounter: input.counter,
      now: input.now,
    },
  });
  const byName = new Map(input.tools.map(tool => [tool.name, tool]));
  const params = {
    ...prepared.params,
    messages: prepared.messages,
    ...(prepared.tools.length ? {tools: prepared.tools} : {}),
    n_predict: input.maxTokens ?? 260,
    temperature: input.temperature ?? 0.2,
    seed: 7,
  } as unknown as ApiCompletionParams;
  const toolCalls: TurnOutput['toolCalls'] = [];
  const pending = new Map<string, {name: string; args: unknown}>();
  let reply = '';
  for await (const event of runAgent({
    engine: input.engine,
    initialParams: params,
    allowedTalentNames: prepared.tools.map(tool => tool.function.name),
    talentLookup: name => byName.get(name),
    triggerMarkers: [],
    messageId: 'turn',
    maxTurns: 3,
  })) {
    if (event.type === 'tool_call_started') {
      pending.set(event.call.id, {
        name: event.call.function.name,
        args: event.call.function.arguments,
      });
    } else if (event.type === 'tool_call_finished') {
      const call = pending.get(event.outcome.callId);
      toolCalls.push({
        name: call?.name ?? '?',
        args: call?.args,
        result:
          (event.outcome as {result?: {summary?: string}}).result?.summary ??
          JSON.stringify(event.outcome),
      });
    } else if (event.type === 'run_finished') {
      reply = event.result.finalResult.content ?? '';
    } else if (event.type === 'run_failed') {
      throw event.error;
    }
  }
  return {
    reply,
    toolCalls,
    prepared,
    history: [...messages, {role: 'assistant', content: reply}],
  };
}
