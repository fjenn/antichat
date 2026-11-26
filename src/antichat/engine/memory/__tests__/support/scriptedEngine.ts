import type {
  ApiCompletionParams,
  CompletionEngine,
  CompletionResult,
} from '../../../../../utils/completionTypes';
import type {ChatMessage} from '../../../prompt/types';
import {messageText} from '../../../context/tokenCounter';

export interface ScriptedCall {
  messages: ChatMessage[];
  params: Record<string, any>;
  system: string;
  /** Text of the last message. */
  last: string;
}

export type Script = (
  call: ScriptedCall,
) =>
  | string
  | {content?: string; tool_calls?: unknown[]}
  | Promise<string | {content?: string; tool_calls?: unknown[]}>;

export interface ScriptedEngine extends CompletionEngine {
  calls: ScriptedCall[];
  stopped: number;
}

/** A model whose answers the test writes. Records every request. */
export function createScriptedEngine(script: Script): ScriptedEngine {
  const engine: ScriptedEngine = {
    calls: [],
    stopped: 0,
    async completion(params: ApiCompletionParams): Promise<CompletionResult> {
      const messages = (params.messages ?? []) as ChatMessage[];
      const call: ScriptedCall = {
        messages,
        params: params as Record<string, any>,
        system:
          messages[0]?.role === 'system' ? messageText(messages[0]).text : '',
        last: messages.length
          ? messageText(messages[messages.length - 1]).text
          : '',
      };
      engine.calls.push(call);
      const answer = await script(call);
      const content =
        typeof answer === 'string' ? answer : (answer.content ?? '');
      return {
        text: content,
        content,
        tool_calls:
          typeof answer === 'string' ? undefined : (answer.tool_calls as any),
      } as CompletionResult;
    },
    async stopCompletion() {
      engine.stopped++;
    },
  };
  return engine;
}

/** A `save_memory`-style tool call in the shape llama.rn returns. */
export function toolCall(name: string, args: Record<string, unknown>) {
  return {
    id: `call_${name}`,
    type: 'function',
    function: {name, arguments: JSON.stringify(args)},
  };
}
