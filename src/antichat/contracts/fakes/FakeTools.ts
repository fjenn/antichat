import {Emitter} from '../common';
import type {Connectivity} from '../connectivity';
import type {ToolsPort, ToolView} from '../tools';

type Definition = Pick<ToolView, 'id' | 'kind' | 'online' | 'selectable'>;

const DEFINITIONS: Definition[] = [
  {id: 'search', kind: 'search', online: true, selectable: true},
  {id: 'think', kind: 'think', online: false, selectable: true},
  {id: 'image', kind: 'image', online: false, selectable: true},
  {id: 'research', kind: 'research', online: true, selectable: true},
  {id: 'study', kind: 'study', online: false, selectable: true},
  {id: 'calculator', kind: 'calculator', online: false, selectable: false},
];

const NEW_CHAT = '\u0000new';

/** Tools that follow the fake network: online tools grey out when offline. */
export class FakeTools extends Emitter implements ToolsPort {
  tools: ToolView[] = [];
  private readonly active = new Map<string, string[]>();
  private readonly consented = new Set<string>();

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
    this.active.delete(conversationId ?? NEW_CHAT);
    this.emit();
  }

  async grantConsent(toolId: string): Promise<void> {
    this.consented.add(toolId);
    this.rebuild();
    this.emit();
  }

  private rebuild(): void {
    this.tools = DEFINITIONS.map(definition => {
      const offline = definition.online && !this.connectivity.online;
      const needsConsent =
        definition.id === 'search' && !this.consented.has('search');
      return {
        ...definition,
        available: !offline,
        unavailableReason: offline
          ? 'offline'
          : needsConsent
            ? 'needs_consent'
            : undefined,
      };
    });
  }
}

const EMPTY: readonly string[] = Object.freeze([]);
