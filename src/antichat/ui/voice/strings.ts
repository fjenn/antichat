/**
 * English strings of the voice UI. They live here until the locale owner
 * moves them into `locales/en.json` under a `voice` key (same names).
 */
export const voiceStrings = {
  dictation: {
    listening: 'Listening…',
    starting: 'Starting…',
    transcribing: 'Finishing…',
    cancel: 'Cancel dictation',
    confirm: 'Use dictated text',
    failed: 'Dictation did not work. Try again.',
    noPermission: 'Allow microphone access in Settings to dictate.',
    start: 'Dictate',
    openSettings: 'Open Settings',
    retry: 'Try again',
    micBusy: 'The microphone is not available right now.',
    noModel: 'Dictation needs its speech model first.',
  },
  readAloud: {
    play: 'Read aloud',
    pause: 'Pause',
    resume: 'Resume',
    stop: 'Stop reading',
    previous: 'Previous sentence',
    next: 'Next sentence',
    speed: 'Speed',
    preparing: 'Preparing voice…',
    failed: 'Reading aloud did not work.',
    sentence: (index: number, count: number) => `${index} of ${count}`,
  },
  mode: {
    starting: 'Getting ready…',
    listening: 'Listening',
    thinking: 'Thinking',
    speaking: 'Speaking',
    muted: 'Muted',
    paused: 'Paused',
    orbInterrupt: 'Interrupt',
    orbResume: 'Resume voice chat',
    mute: 'Mute',
    unmute: 'Unmute',
    end: 'End voice chat',
    tapToInterrupt: 'Tap the orb to interrupt',
    unavailable: 'Voice chat needs more memory than this phone has.',
    failed: 'Voice chat ran into a problem.',
  },
  dictationLanguage: 'Dictation language',
  dictationAutomatic: 'Follows the language you speak',
  picker: {
    title: 'Voice',
    recommended: 'Recommended',
    system: 'Built into this phone',
    download: (size: string) => `Download · ${size}`,
    downloading: (percent: number) => `Downloading ${percent}%`,
    preview: 'Hello, this is how I sound.',
    language: 'Spoken language',
    languageAuto: 'Automatic',
    interrupt: 'Interrupt by speaking',
    fastReplies: 'Faster replies',
    punctuation: 'Punctuation in dictation',
    failed: 'That voice could not be set.',
  },
} as const;

/** Languages offered for dictation; 'auto' follows what is said. */
export const DICTATION_LANGUAGES = [
  {tag: 'auto', name: 'Automatic'},
  {tag: 'en', name: 'English'},
  {tag: 'de', name: 'Deutsch'},
  {tag: 'es', name: 'Español'},
  {tag: 'fr', name: 'Français'},
  {tag: 'it', name: 'Italiano'},
  {tag: 'pt', name: 'Português'},
  {tag: 'nl', name: 'Nederlands'},
  {tag: 'pl', name: 'Polski'},
  {tag: 'sv', name: 'Svenska'},
  {tag: 'da', name: 'Dansk'},
  {tag: 'nb', name: 'Norsk'},
  {tag: 'fi', name: 'Suomi'},
  {tag: 'cs', name: 'Čeština'},
  {tag: 'tr', name: 'Türkçe'},
  {tag: 'el', name: 'Ελληνικά'},
  {tag: 'ru', name: 'Русский'},
  {tag: 'uk', name: 'Українська'},
  {tag: 'ar', name: 'العربية'},
  {tag: 'he', name: 'עברית'},
  {tag: 'hi', name: 'हिन्दी'},
  {tag: 'id', name: 'Bahasa Indonesia'},
  {tag: 'vi', name: 'Tiếng Việt'},
  {tag: 'th', name: 'ไทย'},
  {tag: 'ja', name: '日本語'},
  {tag: 'ko', name: '한국어'},
  {tag: 'zh', name: '中文'},
] as const;

export function formatBytes(bytes: number): string {
  return bytes >= 1e9
    ? `${(bytes / 1e9).toFixed(1)} GB`
    : `${Math.max(1, Math.round(bytes / 1e6))} MB`;
}

export function formatElapsed(ms: number): string {
  const seconds = Math.max(0, Math.floor(ms / 1000));
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;
}
