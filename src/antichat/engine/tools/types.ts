/**
 * Contracts of AntiChat's tool layer (M8).
 *
 * A tool is plain data plus one `execute` function. The same definition is
 * offered to the model (through the D2 seam), run by the harness loop
 * (`runner.ts`) and exposed to upstream's agent runner as a talent
 * (`talentAdapter.ts`).
 */
import type {ToolDefinition} from '../prompt/types';
import type {RichCard} from './cards';

export type {ToolDefinition};

export type JsonSchema = Record<string, any>;

/** A source a tool retrieved; the citation layer numbers these per answer. */
export interface ToolSource {
  /** Number the model cites this source by, once it is registered. */
  n?: number;
  url: string;
  title: string;
  /** Host without `www.`. */
  site: string;
  snippet?: string;
  /** The text the model was shown for this source (snippet or page chunks). */
  evidence?: string;
  publishedAt?: string;
  /** True when the page itself was read, not only its search snippet. */
  fetched?: boolean;
  engine?: string;
}

export interface ToolImage {
  url: string;
  thumbnailUrl?: string;
  title?: string;
  sourceUrl?: string;
  width?: number;
  height?: number;
  license?: string;
}

/** What a tool hands back. `text` is the only part the model reads. */
export interface ToolOutput {
  text: string;
  /** Web content: wrapped as untrusted before it reaches the model. */
  untrusted?: boolean;
  card?: RichCard;
  sources?: ToolSource[];
  images?: ToolImage[];
  /** The tool failed; `text` says why in one line. */
  isError?: boolean;
}

export interface ToolContext {
  signal?: AbortSignal;
  now: Date;
  timeZone?: string;
  locale?: string;
  /** Newest user message, for tools that fall back to it (empty query). */
  userText?: string;
  /** Context window of the loaded model; budgets scale with it. */
  nCtx?: number;
  /** Device capability class (A = 4 GB … D = 12 GB+). */
  deviceClass?: 'A' | 'B' | 'C' | 'D';
  /** Chat the call belongs to (source numbering continues within a turn). */
  turnId?: string;
  onProgress?: (note: string, fraction?: number) => void;
}

export type ToolKind = 'local' | 'online';

export interface AntichatTool {
  name: string;
  /** One sentence; trimmed to 180 characters when offered. */
  description: string;
  parameters: JsonSchema;
  /** `online` tools are withheld when the device has no connection. */
  kind: ToolKind;
  /**
   * `always`: in every request (subject to the cap). `chip`: only while its
   * chip is on for the chat. `deferred`: found through `search_tools`.
   */
  tier: 'always' | 'chip' | 'deferred';
  /** Chip that switches this tool on (`search`, `study`, …). */
  chip?: string;
  /** Extra words for the tool index. */
  keywords?: string[];
  /**
   * Words that mean "this tool" when the user says them ("weather",
   * "timer"). A message that names another tool is not searched first.
   */
  triggers?: string[];
  timeoutMs?: number;
  /** Result is cut to this many characters before the model sees it. */
  resultCap?: number;
  /** Fill-ins applied before validation (missing scheme, empty query…). */
  normalize?: (
    args: Record<string, unknown>,
    context: ToolContext,
  ) => Record<string, unknown>;
  /** A minimal valid call, quoted in the repair prompt. */
  example?: Record<string, unknown>;
  execute(args: Record<string, any>, context: ToolContext): Promise<ToolOutput>;
}

export interface ToolCall {
  id: string;
  name: string;
  /** Raw argument text as the model wrote it. */
  argumentsText: string;
}

export function toToolDefinition(
  tool: Pick<AntichatTool, 'name' | 'description' | 'parameters'>,
): ToolDefinition {
  return {
    type: 'function',
    function: {
      name: tool.name,
      description: trimDescription(tool.description),
      parameters: tool.parameters,
    },
  };
}

const MAX_DESCRIPTION = 180;

/** First sentence, at most 180 characters (Mac tier rule). */
export function trimDescription(description: string): string {
  const text = description.replace(/\s+/g, ' ').trim();
  if (text.length <= MAX_DESCRIPTION) {
    return text;
  }
  const sentence = text.slice(0, MAX_DESCRIPTION);
  const stop = sentence.lastIndexOf('. ');
  return stop > 60 ? sentence.slice(0, stop + 1) : sentence.trimEnd();
}
