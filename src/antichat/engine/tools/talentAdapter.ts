/**
 * AntiChat tools as upstream talents, so PocketPal's agent runner can
 * dispatch them. The adapter routes every call through `executeGuarded`:
 * a malformed call comes back as the repair prompt (the runner feeds it to
 * the model as the tool result, which is exactly the one-retry design), a
 * duplicate call as the duplicate notice, a slow tool as a timeout notice.
 */
import type {
  TalentEngine,
  TalentExecuteContext,
  TalentResult,
  ToolDefinition,
} from '../../../services/talents/types';
import {executeGuarded} from './execute';
import {LOOP_POLICY, LoopGuard} from './loopGuard';
import {RepairState} from './repair';
import {currentTurn} from './turnState';
import {toToolDefinition, type AntichatTool} from './types';

let callCounter = 0;

export function asTalentEngine(tool: AntichatTool): TalentEngine {
  return {
    name: tool.name,
    toToolDefinition: (): ToolDefinition => toToolDefinition(tool),
    async execute(
      args: Record<string, any>,
      talentContext?: TalentExecuteContext,
    ): Promise<TalentResult> {
      const turn = currentTurn();
      const guards = turn?.guards ?? {
        repair: new RepairState(),
        guard: new LoopGuard(LOOP_POLICY.B),
      };
      const offered = turn?.offered.some(
        candidate => candidate.name === tool.name,
      )
        ? turn.offered
        : [...(turn?.offered ?? []), tool];
      const result = await executeGuarded({
        callId: `talent-${Date.now().toString(36)}-${callCounter++}`,
        turnId: turn?.turnId ?? 'no-turn',
        name: tool.name,
        rawArguments: args,
        offered,
        guards,
        context: {
          ...(turn?.context ?? {now: new Date()}),
          signal: talentContext?.signal ?? turn?.context.signal,
        },
        resultChars: turn?.resultChars,
      });
      if (result.status !== 'ok') {
        return {
          type: 'error',
          summary: result.content,
          errorMessage: result.content,
        };
      }
      const sources = result.output?.sources;
      if (tool.name === 'web_search' && sources?.length) {
        return {
          type: 'search',
          query: String(result.args?.query ?? ''),
          results: sources.map(source => ({
            title: source.title,
            url: source.url,
            snippet: source.snippet ?? '',
          })),
          summary: result.content,
        };
      }
      return {
        type: 'text',
        summary: result.content,
        ...(sources?.length ? {links: sources.map(source => source.url)} : {}),
      };
    },
  };
}
