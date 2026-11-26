/**
 * Contracts of the D2 send-pipeline seam.
 *
 * `prepareRequest({messages, session}) → {messages, tools, params}` is the one
 * place where hidden behaviour (system prompt, memory, context fitting, tool
 * selection, search gate) reaches a completion request. Milestones register a
 * `RequestProvider`; none of them edits `src/hooks/useChatSession.ts`.
 */
import type {
  ApiCompletionParams,
  CompletionEngine,
} from '../../../utils/completionTypes';
import type {ToolDefinition} from '../../../services/talents/types';
import type {TokenCounter} from '../context/tokenCounter';
import type {ModelFamily} from './modelFamily';

export type {ToolDefinition};

/** An OpenAI-style chat message as llama.rn takes it. */
export interface ChatMessage {
  role: string;
  content?: unknown;
  tool_calls?: unknown[];
  tool_call_id?: string;
  reasoning_content?: string;
  [key: string]: unknown;
}

/**
 * Device capability class from the gap analysis (A = 4 GB … D = 12 GB+).
 * Unknown devices are treated as B.
 */
export type DeviceClass = 'A' | 'B' | 'C' | 'D';

/** What the seam knows about the chat the request belongs to. */
export interface SessionInfo {
  /** Chat id; undefined for a chat that has no row yet. */
  id?: string;
  /** The reply will be spoken (voice mode). */
  spoken?: boolean;
  /** Study mode is on for this chat. */
  studyMode?: boolean;
  /** "Think longer" is on for this message. */
  thinking?: boolean;
  /** Temporary chats never write summaries or memories to disk. */
  temporary?: boolean;
  /**
   * Offline chat: nothing leaves the phone (no online tools, no location) and
   * memory is read-only.
   */
  offline?: boolean;
  /** The project the chat belongs to, if any. */
  projectId?: string | null;
  /** BCP-47 locale of the app, e.g. "de-DE". */
  locale?: string;
  /** ISO 3166-1 alpha-2 country for the helpline table. */
  countryCode?: string;
}

/** What the seam knows about the loaded model and the device. */
export interface RuntimeInfo {
  /** Context window of the loaded model, in tokens. */
  nCtx: number;
  family: ModelFamily;
  modelName?: string;
  deviceClass: DeviceClass;
  tokenCounter: TokenCounter;
  /** Engine for side generations (summaries). Absent in pure unit tests. */
  engine?: CompletionEngine;
  signal?: AbortSignal;
  now: Date;
  /** IANA time zone, e.g. "Europe/Berlin". */
  timeZone?: string;
  /**
   * The model's own default system prompt ("You are a helpful assistant…").
   * When upstream put exactly this at the start of the system message, it is
   * dropped: AntiChat's base prompt replaces it.
   */
  modelDefaultSystemPrompt?: string;
}

export interface PrepareRequestInput {
  messages: ChatMessage[];
  session: SessionInfo;
  /** Tools already on the request (pal talents). */
  tools?: ToolDefinition[];
  /** Completion params already on the request. */
  params?: Partial<ApiCompletionParams>;
  runtime?: Partial<RuntimeInfo>;
}

/**
 * Where a system-prompt block sits. The order is the cache contract:
 * `stable` blocks never change within an install's settings, `session` blocks
 * change at most once per chat or per day and sit at the end of the system
 * message. Anything that changes per turn must use `turnContext` instead,
 * which rides on the newest user message and leaves the whole history cached.
 */
export type SystemSlot = 'stable' | 'session';

export interface SystemBlock {
  id: string;
  slot: SystemSlot;
  /** Lower comes first within the slot. Default 100. */
  order?: number;
  text: string;
  /**
   * 'tools': keep the block only when the finished request offers at least
   * one tool, whoever contributed it.
   */
  when?: 'tools';
}

export interface Contribution {
  systemBlocks?: SystemBlock[];
  /** Short lines appended to the newest user message (never persisted). */
  turnContext?: string[];
  /** Tools to offer in addition to the ones on the request. */
  tools?: ToolDefinition[];
  /** Names of tools to withhold for this turn (e.g. search while offline). */
  removeTools?: string[];
  params?: Partial<ApiCompletionParams>;
  /** Free-form facts for the UI (which memories were used, crisis card…). */
  meta?: Record<string, unknown>;
}

export interface RequestContext {
  /** The messages as upstream assembled them. Do not mutate. */
  readonly messages: readonly ChatMessage[];
  readonly session: SessionInfo;
  readonly runtime: RuntimeInfo;
  readonly tools: readonly ToolDefinition[];
  readonly params: Readonly<Partial<ApiCompletionParams>>;
  /** Text of the newest user message. */
  readonly userText: string;
}

export interface RequestDraft {
  messages: ChatMessage[];
  tools: ToolDefinition[];
  params: Partial<ApiCompletionParams>;
  meta: Record<string, unknown>;
}

export interface RequestProvider {
  id: string;
  /** Lower runs first. Default 100. */
  order?: number;
  /** Add system blocks, turn context, tools or params. */
  contribute?(
    context: RequestContext,
  ): Promise<Contribution | void> | Contribution | void;
  /**
   * Rewrite the assembled request (context fitting, history clean-up). Runs
   * after every contribution has been folded in.
   */
  transform?(
    draft: RequestDraft,
    context: RequestContext,
  ): Promise<RequestDraft | void> | RequestDraft | void;
}

export interface PreparedRequest {
  messages: ChatMessage[];
  tools: ToolDefinition[];
  params: Partial<ApiCompletionParams>;
  meta: Record<string, unknown>;
  /** False when no provider is registered: the input came back untouched. */
  changed: boolean;
}
