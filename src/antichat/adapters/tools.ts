/**
 * Tools adapter: what the composer's + sheet can switch on for the next
 * message. The first version has one switch, web search; everything else
 * the engine offers the model on its own (`engine/tools/selection`).
 *
 * The switch is UI state until the message is sent; the chat adapter then
 * arms the engine's one-shot Search chip for that request.
 */
import {Emitter} from '../contracts/common';
import type {Connectivity} from '../contracts/connectivity';
import type {ToolsPort, ToolView} from '../contracts/tools';

const NEW_CHAT = '\u0000new';
const EMPTY: readonly string[] = Object.freeze([]);

export class SearchSwitchTools extends Emitter implements ToolsPort {
  tools: ToolView[] = [];
  private readonly active = new Map<string, string[]>();

  constructor(private readonly connectivity: Connectivity) {
    super();
    this.rebuild();
    connectivity.subscribe(() => {
      this.rebuild();
      this.emit();
    });
  }

  activeToolIds(conversationId: string | null): readonly string[] {
    return this.active.get(conversationId ?? NEW_CHAT) ?? EMPTY;
  }

  setActive(
    conversationId: string | null,
    toolId: string,
    active: boolean,
  ): void {
    const key = conversationId ?? NEW_CHAT;
    const rest = this.activeToolIds(conversationId).filter(id => id !== toolId);
    this.active.set(key, active ? [...rest, toolId] : rest);
    this.emit();
  }

  clearActive(conversationId: string | null): void {
    if (this.active.delete(conversationId ?? NEW_CHAT)) {
      this.emit();
    }
  }

  async grantConsent(): Promise<void> {}

  private rebuild(): void {
    const online = this.connectivity.online;
    this.tools = [
      {
        id: 'search',
        kind: 'search',
        online: true,
        selectable: true,
        available: online,
        unavailableReason: online ? undefined : 'offline',
      },
    ];
  }
}

let port: ToolsPort | undefined;

export function toolsPort(connectivity: Connectivity): ToolsPort {
  port ??= new SearchSwitchTools(connectivity);
  return port;
}
