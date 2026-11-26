/**
 * Personalisation (H8): personality preset, four dials, "about you" and
 * custom instructions. This file is the settings schema M6's Personalization
 * screen edits, and the renderer that turns it into system-prompt blocks.
 *
 * One concrete sentence per choice: what to do, not "more X than usual".
 * The vague wording barely moved Gemma 4 E2B (2026-11-25: "efficient" was not
 * shorter, presets looked alike); behaviours it can act on do. Plus ChatGPT's
 * framing that the profile is "not relevant to most requests".
 */
import AsyncStorage from '@react-native-async-storage/async-storage';

import type {DeviceClass, SystemBlock} from './types';

export type PersonalityPreset =
  | 'default'
  | 'professional'
  | 'friendly'
  | 'candid'
  | 'quirky'
  | 'efficient'
  | 'cynical';

export type Dial = 'less' | 'default' | 'more';

export interface PersonalizationSettings {
  /** Master switch ("Enable customisation"). */
  enabled: boolean;
  preset: PersonalityPreset;
  warmth: Dial;
  enthusiasm: Dial;
  headersAndLists: Dial;
  emoji: Dial;
  /** "How should AntiChat respond?" */
  customInstructions: string;
  nickname: string;
  occupation: string;
  /** "More about you". */
  aboutYou: string;
}

export const DEFAULT_PERSONALIZATION: PersonalizationSettings = {
  enabled: true,
  preset: 'default',
  warmth: 'default',
  enthusiasm: 'default',
  headersAndLists: 'default',
  emoji: 'default',
  customInstructions: '',
  nickname: '',
  occupation: '',
  aboutYou: '',
};

/** Input limits for the settings screen (ChatGPT uses 1,500 per field). */
export const PERSONALIZATION_LIMITS = {
  customInstructions: 1500,
  aboutYou: 1500,
  nickname: 50,
  occupation: 100,
} as const;

export const PERSONALITY_PRESETS: Record<
  PersonalityPreset,
  {label: string; summary: string; prompt: string}
> = {
  default: {label: 'Default', summary: 'Balanced style and tone', prompt: ''},
  professional: {
    label: 'Professional',
    summary: 'Polished and precise',
    prompt:
      'Style: professional. Write in a polished, formal tone with precise wording; no slang, no jokes, no exclamation marks, no emoji.',
  },
  friendly: {
    label: 'Friendly',
    summary: 'Warm and chatty',
    prompt:
      "Style: friendly. Write like a warm, chatty friend: casual words, contractions, and a kind remark about the user's situation.",
  },
  candid: {
    label: 'Candid',
    summary: 'Direct and encouraging',
    prompt:
      'Style: candid. Say plainly what you really think, including the downsides or what the user may be getting wrong, then end with one line of encouragement.',
  },
  quirky: {
    label: 'Quirky',
    summary: 'Playful and imaginative',
    prompt:
      'Style: quirky. Be playful and imaginative: put a funny comparison or a bit of wordplay in every answer.',
  },
  efficient: {
    label: 'Efficient',
    summary: 'Concise and plain',
    prompt:
      'Style: efficient. Give the shortest answer that fully helps, in plain words: no greeting, no intro sentence, no closing line, no filler.',
  },
  cynical: {
    label: 'Cynical',
    summary: 'Critical and sarcastic',
    prompt:
      'Style: cynical. Be dry and sarcastic: add a wry, sceptical aside or two, but still give the full, correct help and never insult the user.',
  },
};

const DIAL_SENTENCES: Record<
  'warmth' | 'enthusiasm' | 'headersAndLists' | 'emoji',
  {more: string; less: string}
> = {
  warmth: {
    more: 'Be extra warm: acknowledge how the user may feel and add a kind, encouraging word.',
    less: 'Be neutral and matter-of-fact: no sympathy, reassurance or encouragement.',
  },
  enthusiasm: {
    more: 'Be enthusiastic and upbeat: show excitement about the topic, with an exclamation mark or two.',
    less: 'Keep a calm, flat tone: no exclamation marks and no excited words.',
  },
  headersAndLists: {
    more: 'Structure every answer with short Markdown headers (##) and bulleted lists.',
    less: 'Write in plain paragraphs only: no headers and no lists.',
  },
  emoji: {
    more: 'Use several fitting emoji in every answer, for example at the start of key points.',
    less: 'Never use emoji.',
  },
};

/** Characters of user-written text that go into the prompt, by device class. */
export const USER_TEXT_BUDGET: Record<DeviceClass, number> = {
  A: 500,
  B: 1000,
  C: 2000,
  D: 3000,
};

export const ABOUT_HEADER = '# About the user';
export const ABOUT_FRAMING =
  'The user wrote this profile for all their chats, so it is not relevant to most requests. Use it only when it clearly helps, and do not mention it otherwise.';
/** The user's style choices win over the base style (lists, warmth). */
export const STYLE_HEADER =
  '# Style the user chose (follow it even where it differs from the guidance above)';
export const INSTRUCTIONS_HEADER = '# How the user wants you to respond';

const clip = (text: string, limit: number): string => {
  const collapsed = text.replace(/\r\n?/g, '\n').trim();
  if (collapsed.length <= limit) {
    return collapsed;
  }
  const cut = collapsed.slice(0, limit);
  const lastBreak = Math.max(cut.lastIndexOf(' '), cut.lastIndexOf('\n'));
  return `${(lastBreak > limit * 0.6 ? cut.slice(0, lastBreak) : cut).trimEnd()}…`;
};

/** The style sentences: preset first, then one sentence per moved dial. */
export function renderStyle(settings: PersonalizationSettings): string {
  const sentences: string[] = [];
  const preset = PERSONALITY_PRESETS[settings.preset]?.prompt;
  if (preset) {
    sentences.push(preset);
  }
  (Object.keys(DIAL_SENTENCES) as Array<keyof typeof DIAL_SENTENCES>).forEach(
    key => {
      const value = settings[key];
      if (value === 'more' || value === 'less') {
        sentences.push(DIAL_SENTENCES[key][value]);
      }
    },
  );
  return sentences.join(' ');
}

/**
 * System blocks for the user's personalisation, all in the stable slot (they
 * change only when the user edits settings). User text is clipped to the
 * device budget: instructions get two thirds, the profile one third.
 */
export function personalizationBlocks(
  settings: PersonalizationSettings | null | undefined,
  deviceClass: DeviceClass = 'B',
): SystemBlock[] {
  if (!settings || !settings.enabled) {
    return [];
  }
  const blocks: SystemBlock[] = [];
  const style = renderStyle(settings);
  if (style) {
    blocks.push({
      id: 'style',
      slot: 'stable',
      order: 30,
      text: `${STYLE_HEADER}\n${style}`,
    });
  }

  const budget = USER_TEXT_BUDGET[deviceClass] ?? USER_TEXT_BUDGET.B;
  const hasInstructions = settings.customInstructions.trim().length > 0;
  const profileBudget = hasInstructions ? Math.floor(budget / 3) : budget;

  const profile: string[] = [];
  if (settings.nickname.trim()) {
    profile.push(
      `Name: ${clip(settings.nickname, PERSONALIZATION_LIMITS.nickname)}`,
    );
  }
  if (settings.occupation.trim()) {
    profile.push(
      `Occupation: ${clip(settings.occupation, PERSONALIZATION_LIMITS.occupation)}`,
    );
  }
  if (settings.aboutYou.trim()) {
    const used = profile.join('\n').length;
    profile.push(clip(settings.aboutYou, Math.max(80, profileBudget - used)));
  }
  if (profile.length) {
    blocks.push({
      id: 'about-user',
      slot: 'stable',
      order: 40,
      text: `${ABOUT_HEADER}\n${ABOUT_FRAMING}\n${profile.join('\n')}`,
    });
  }

  if (hasInstructions) {
    const used = profile.join('\n').length;
    blocks.push({
      id: 'custom-instructions',
      slot: 'stable',
      order: 50,
      text: `${INSTRUCTIONS_HEADER}\n${clip(
        settings.customInstructions,
        Math.max(160, budget - Math.min(used, profileBudget)),
      )}`,
    });
  }
  return blocks;
}

// ---------------------------------------------------------------------------
// Settings holder. M6's screen reads and writes through these; the system
// prompt provider reads the current value on every request.
// ---------------------------------------------------------------------------

const STORAGE_KEY = 'antichat.personalization.v1';
type Listener = (settings: PersonalizationSettings) => void;

let current: PersonalizationSettings = {...DEFAULT_PERSONALIZATION};
const listeners = new Set<Listener>();

export function getPersonalization(): PersonalizationSettings {
  return current;
}

/** Merge a patch, clamp field lengths, notify and persist. */
export function setPersonalization(
  patch: Partial<PersonalizationSettings>,
  persist = true,
): PersonalizationSettings {
  const next = {...current, ...patch};
  next.customInstructions = next.customInstructions.slice(
    0,
    PERSONALIZATION_LIMITS.customInstructions,
  );
  next.aboutYou = next.aboutYou.slice(0, PERSONALIZATION_LIMITS.aboutYou);
  next.nickname = next.nickname.slice(0, PERSONALIZATION_LIMITS.nickname);
  next.occupation = next.occupation.slice(0, PERSONALIZATION_LIMITS.occupation);
  if (!PERSONALITY_PRESETS[next.preset]) {
    next.preset = 'default';
  }
  current = next;
  listeners.forEach(listener => listener(current));
  if (persist) {
    try {
      AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(current)).catch(
        () => {},
      );
    } catch {
      // Storage is unavailable; the setting still applies to this run.
    }
  }
  return current;
}

export function subscribePersonalization(listener: Listener): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/** Load saved settings; call once at start-up. */
export async function loadPersonalization(): Promise<PersonalizationSettings> {
  try {
    const raw = await AsyncStorage.getItem(STORAGE_KEY);
    if (raw) {
      setPersonalization(
        {...DEFAULT_PERSONALIZATION, ...JSON.parse(raw)},
        false,
      );
    }
  } catch {
    // Corrupt or missing settings fall back to the defaults.
  }
  return current;
}

/** Test helper. */
export function resetPersonalization(): void {
  current = {...DEFAULT_PERSONALIZATION};
}
