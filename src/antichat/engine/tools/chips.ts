/**
 * Per-chat tool chips (correction 4 of the gap analysis: upstream switches
 * tools on per pal; AntiChat needs its own selection). A chip is a named
 * switch the composer shows; the engine keeps which chips are on per chat and
 * which deferred tools `search_tools` has activated there.
 *
 * In memory on purpose: the UI half persists chip state with the chat row and
 * re-seeds it through `setChips` when a chat is opened.
 */

export type ChipId =
  | 'search'
  | 'think'
  | 'study'
  | 'image'
  | 'research'
  | string;

export interface ChipInfo {
  id: ChipId;
  /** Needs a connection: greyed with "Needs a connection" when offline. */
  online: boolean;
  /** One-shot chips switch themselves off after the next send. */
  oneShot?: boolean;
}

export const CHIPS: ChipInfo[] = [
  {id: 'search', online: true, oneShot: true},
  {id: 'research', online: true, oneShot: true},
  {id: 'image', online: false, oneShot: true},
  {id: 'think', online: false},
  {id: 'study', online: false},
];

const NO_CHAT = '';

interface ChatToolState {
  chips: Set<ChipId>;
  /** Deferred tools found through `search_tools`, in activation order. */
  activated: string[];
}

const states = new Map<string, ChatToolState>();
const listeners = new Set<(chatId: string) => void>();

const stateOf = (chatId?: string): ChatToolState => {
  const key = chatId ?? NO_CHAT;
  let state = states.get(key);
  if (!state) {
    state = {chips: new Set(), activated: []};
    states.set(key, state);
  }
  return state;
};

const notify = (chatId?: string) =>
  listeners.forEach(listener => listener(chatId ?? NO_CHAT));

export function setChip(
  chatId: string | undefined,
  chip: ChipId,
  on: boolean,
): void {
  const state = stateOf(chatId);
  if (on === state.chips.has(chip)) {
    return;
  }
  if (on) {
    state.chips.add(chip);
  } else {
    state.chips.delete(chip);
  }
  notify(chatId);
}

export function setChips(chatId: string | undefined, chips: ChipId[]): void {
  stateOf(chatId).chips = new Set(chips);
  notify(chatId);
}

export function activeChips(chatId?: string): ChipId[] {
  return [...stateOf(chatId).chips];
}

export function isChipOn(chatId: string | undefined, chip: ChipId): boolean {
  return stateOf(chatId).chips.has(chip);
}

/** Switch one-shot chips off; called once the request has been built. */
export function consumeOneShotChips(chatId?: string): ChipId[] {
  const state = stateOf(chatId);
  const used = CHIPS.filter(
    chip => chip.oneShot && state.chips.has(chip.id),
  ).map(chip => chip.id);
  used.forEach(chip => state.chips.delete(chip));
  if (used.length) {
    notify(chatId);
  }
  return used;
}

export function activateTools(
  chatId: string | undefined,
  names: string[],
  limit = 6,
): void {
  const state = stateOf(chatId);
  for (const name of names) {
    const at = state.activated.indexOf(name);
    if (at !== -1) {
      state.activated.splice(at, 1);
    }
    state.activated.push(name);
  }
  // Oldest activations fall out first, so the offered set stays small.
  while (state.activated.length > limit) {
    state.activated.shift();
  }
}

export function activatedTools(chatId?: string): string[] {
  return [...stateOf(chatId).activated];
}

export function subscribeChips(listener: (chatId: string) => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function forgetChat(chatId?: string): void {
  states.delete(chatId ?? NO_CHAT);
}

/** Test helper. */
export function resetChipState(): void {
  states.clear();
}
