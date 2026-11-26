/**
 * ToolsPort: which tools exist on this phone and which are switched on for
 * the next message. M8 implements it; the composer's + sheet and tool chips
 * read it.
 */
import type {Observable} from './common';

export interface ToolView {
  id: string;
  /** Key the UI words and draws: `tools.<kind>` in the locale file. */
  kind:
    | 'search'
    | 'think'
    | 'image'
    | 'research'
    | 'study'
    | 'calculator'
    | 'connector'
    | 'other';
  /** Name for tools the locale file cannot know (connectors, MCP servers). */
  displayName?: string;
  /** Needs a network connection. */
  online: boolean;
  /**
   * Usable right now. An online tool is unavailable while offline; a tool the
   * phone cannot run is not listed at all.
   */
  available: boolean;
  unavailableReason?: 'offline' | 'model_lacks' | 'needs_consent';
  /** Shown in the composer's + sheet (the rest work without being picked). */
  selectable: boolean;
}

export interface ToolsPort extends Observable {
  readonly tools: readonly ToolView[];
  /** Tools switched on for the next message, as chips in the composer. */
  activeToolIds(conversationId: string | null): readonly string[];
  setActive(
    conversationId: string | null,
    toolId: string,
    active: boolean,
  ): void;
  clearActive(conversationId: string | null): void;
  /** One-time consent before the first web search. */
  grantConsent(toolId: string): Promise<void>;
}
