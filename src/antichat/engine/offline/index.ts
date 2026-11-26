/**
 * Offline chat: a chat in which nothing leaves the phone. It replaces the
 * temporary-chat toggle in the top bar (same place, same feel).
 *
 * In an offline chat
 *  - no tool that can reach the network is offered or run (web search, page
 *    reader, weather, image search, connectors, location);
 *  - memory is read-only: saved memories may be used, nothing new is written
 *    (no save/forget tools, no extraction, no digest);
 *  - the chat is saved in history like any other, with a small marker.
 *
 * The flag lives here (AsyncStorage, a set of chat ids) rather than in
 * antichat.db, so the store schema stays as it is. Stale ids of deleted chats
 * are harmless.
 */
import AsyncStorage from '@react-native-async-storage/async-storage';
import {makeAutoObservable, runInAction} from 'mobx';

const STORAGE_KEY = 'antichat.offlineChats.v1';

/**
 * Tools that reach the network although their catalogue kind is `local`, and
 * upstream talents that do. Online catalogue tools (web, weather, connectors)
 * are caught by their kind.
 */
export const NETWORK_TOOL_NAMES: ReadonlySet<string> = new Set([
  'web_search',
  'read_url',
  'image_search',
  'weather',
  'get_location',
]);

/** Memory writes: off in an offline chat (memory is read-only there). */
export const MEMORY_WRITE_TOOL_NAMES: ReadonlySet<string> = new Set([
  'save_memory',
  'forget_memory',
]);

/** Said next to a message that would need the web, in an offline chat. */
export const OFFLINE_CHAT_NOTE =
  'This is an offline chat: web search and other online tools are switched off for it. If the answer needs current information, say in one sentence that you cannot look it up in an offline chat, then answer from what you know.';

export class OfflineChats {
  /** Chats started as offline chats. */
  ids = new Set<string>();
  /**
   * The chat being started is an offline chat. Upstream gives a chat its id
   * only with the first message, so the request seam claims that id.
   */
  armed = false;
  loaded = false;

  constructor() {
    makeAutoObservable(this);
  }

  has(sessionId?: string | null): boolean {
    return !!sessionId && this.ids.has(sessionId);
  }

  mark(sessionId: string): void {
    if (!sessionId || this.ids.has(sessionId)) {
      return;
    }
    this.ids.add(sessionId);
    this.save();
  }

  /** The next chat that gets an id is an offline chat. */
  arm(): void {
    this.armed = true;
  }

  disarm(): void {
    this.armed = false;
  }

  /**
   * Called by the request seam for every request: while armed, the first
   * chat id seen becomes an offline chat. Returns whether the chat is one.
   */
  claim(sessionId?: string | null): boolean {
    if (this.armed && sessionId && !this.ids.has(sessionId)) {
      this.armed = false;
      this.mark(sessionId);
    }
    return this.has(sessionId);
  }

  /** Called once at start-up; ids marked before it finishes are kept. */
  async load(): Promise<void> {
    let stored: string[] = [];
    try {
      const raw = await AsyncStorage.getItem(STORAGE_KEY);
      const parsed = raw ? JSON.parse(raw) : [];
      stored = Array.isArray(parsed)
        ? parsed.filter((id): id is string => typeof id === 'string')
        : [];
    } catch {
      // Unreadable: no offline chats.
    }
    runInAction(() => {
      stored.forEach(id => this.ids.add(id));
      this.loaded = true;
    });
  }

  /** Tests. */
  reset(): void {
    this.ids.clear();
    this.armed = false;
    this.loaded = false;
  }

  private save(): void {
    AsyncStorage.setItem(STORAGE_KEY, JSON.stringify([...this.ids])).catch(
      () => {},
    );
  }
}

export const offlineChats = new OfflineChats();

let loading: Promise<void> | null = null;

/** Load once (idempotent). */
export function loadOfflineChats(): Promise<void> {
  loading ??= offlineChats.load();
  return loading;
}

export function isOfflineChat(sessionId?: string | null): boolean {
  return offlineChats.has(sessionId);
}

/** The chat id at the start of a tool turn id (`<chat>:<time>:<n>`). */
export function chatOfTurn(turnId?: string): string | undefined {
  if (!turnId) {
    return undefined;
  }
  const at = turnId.indexOf(':');
  return at > 0 ? turnId.slice(0, at) : undefined;
}

/**
 * True when a tool may be offered in an offline chat: it is local, does not
 * touch the network, and does not write memories.
 */
export function allowedOffline(
  name: string,
  kindOf?: (name: string) => 'local' | 'online' | undefined,
): boolean {
  if (NETWORK_TOOL_NAMES.has(name) || MEMORY_WRITE_TOOL_NAMES.has(name)) {
    return false;
  }
  return kindOf?.(name) !== 'online';
}
