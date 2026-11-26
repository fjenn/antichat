/**
 * A scripted voice port for the dev screen and the UI tests: dictation that
 * hears a phrase word by word, read-aloud that walks through sentences, and
 * a voice session that cycles listening → thinking → speaking.
 */
import type {
  DictationState,
  SpeechState,
  VoiceModeState,
  VoiceOption,
  VoicePort,
  VoicePortEvent,
  VoiceSettings,
} from '../../../engine/voice/port';

const PHRASE = 'What should I cook tonight with what is in the fridge';
const HEARD = 'Tell me something about Paris';

export class DemoVoice implements VoicePort {
  dictation: DictationState = {status: 'idle'};
  speech: SpeechState = {status: 'idle'};
  voiceMode: VoiceModeState = {status: 'off'};
  voices: VoiceOption[] = [
    {
      id: 'phonon:Juniper',
      displayName: 'Juniper',
      languageTag: 'en-US',
      gender: 'f',
      installed: true,
      downloadBytes: 171_554_733,
      recommended: true,
    },
    {
      id: 'kokoro:af_heart',
      displayName: 'Heart',
      languageTag: 'en-US',
      gender: 'f',
      installed: false,
      downloadBytes: 346_030_080,
      recommended: false,
    },
    {
      id: 'supertonic:F1',
      displayName: 'Sol',
      languageTag: 'multi',
      gender: 'f',
      installed: false,
      downloadBytes: 398_352_949,
      recommended: false,
    },
    {
      id: 'system:default',
      displayName: 'System',
      languageTag: 'multi',
      installed: true,
      downloadBytes: 0,
      recommended: false,
    },
  ];
  voiceId: string | null = null;
  settings: VoiceSettings = {
    language: 'auto',
    punctuation: true,
    fastReplies: true,
    bargeIn: true,
    pronunciations: [],
  };
  voiceModeAvailable = true;
  latency = null;
  /** What `pronounce` was last asked to say. */
  pronounced: string[] = [];

  private listeners = new Set<() => void>();
  private eventListeners = new Set<(event: VoicePortEvent) => void>();
  private timers: ReturnType<typeof setInterval>[] = [];
  private rate = 1;

  constructor(private readonly stepMs = 220) {}

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };

  onEvent = (listener: (event: VoicePortEvent) => void) => {
    this.eventListeners.add(listener);
    return () => {
      this.eventListeners.delete(listener);
    };
  };

  private emit(): void {
    this.listeners.forEach(listener => listener());
  }

  private every(
    fn: () => void,
    ms = this.stepMs,
  ): ReturnType<typeof setInterval> {
    const timer = setInterval(fn, ms);
    this.timers.push(timer);
    return timer;
  }

  private clear(): void {
    this.timers.forEach(clearInterval);
    this.timers = [];
  }

  dispose(): void {
    this.clear();
  }

  // Dictation
  async startDictation(): Promise<void> {
    this.clear();
    const words = PHRASE.split(' ');
    const startedAt = Date.now();
    let count = 0;
    this.dictation = {
      status: 'listening',
      partial: '',
      stableLength: 0,
      level: 0,
      startedAt,
    };
    this.emit();
    this.every(() => {
      count = Math.min(words.length, count + 1);
      const partial = words.slice(0, count).join(' ');
      this.dictation = {
        status: 'listening',
        partial,
        stableLength: words.slice(0, Math.max(0, count - 2)).join(' ').length,
        level: 0.25 + 0.6 * Math.abs(Math.sin(count * 1.7)),
        startedAt,
      };
      this.emit();
    });
  }

  async finishDictation(): Promise<string> {
    this.clear();
    const text =
      this.dictation.status === 'listening' ? this.dictation.partial : '';
    this.dictation = {status: 'idle'};
    this.emit();
    return text;
  }

  cancelDictation(): void {
    this.clear();
    this.dictation = {status: 'idle'};
    this.emit();
  }

  // Read aloud
  async speak(messageId: string, text: string): Promise<void> {
    this.clear();
    const count = Math.max(1, text.split(/[.!?]\s+/).filter(Boolean).length);
    let sentence = 0;
    const set = (status: 'speaking' | 'paused') => {
      this.speech = {
        status,
        messageId,
        sentence,
        sentenceCount: count,
        progress: sentence / count,
        range: null,
        rate: this.rate,
      };
      this.emit();
    };
    set('speaking');
    this.every(() => {
      if (this.speech.status !== 'speaking') {
        return;
      }
      sentence++;
      if (sentence >= count) {
        this.stopSpeech();
      } else {
        set('speaking');
      }
    }, this.stepMs * 4);
  }

  pauseSpeech(): void {
    if (this.speech.status === 'speaking') {
      this.speech = {...this.speech, status: 'paused'};
      this.emit();
    }
  }

  resumeSpeech(): void {
    if (this.speech.status === 'paused') {
      this.speech = {...this.speech, status: 'speaking'};
      this.emit();
    }
  }

  stopSpeech(): void {
    this.clear();
    this.speech = {status: 'idle'};
    this.emit();
  }

  seekSpeech(sentence: number): void {
    const state = this.speech;
    if (state.status === 'speaking' || state.status === 'paused') {
      const next = Math.max(0, Math.min(state.sentenceCount - 1, sentence));
      this.speech = {
        ...state,
        sentence: next,
        progress: next / state.sentenceCount,
      };
      this.emit();
    }
  }

  skipSpeech(direction: -1 | 1): void {
    if (this.speech.status === 'speaking' || this.speech.status === 'paused') {
      this.seekSpeech(this.speech.sentence + direction);
    }
  }

  setSpeechRate(rate: number): void {
    this.rate = rate;
    if (this.speech.status === 'speaking' || this.speech.status === 'paused') {
      this.speech = {...this.speech, rate};
    }
    this.emit();
  }

  async pronounce(text: string): Promise<void> {
    this.pronounced.push(text);
  }

  // Voice mode
  async startVoiceMode(): Promise<void> {
    this.clear();
    this.voiceMode = {status: 'starting'};
    this.emit();
    let tick = 0;
    const words = HEARD.split(' ');
    this.every(() => {
      if (
        this.voiceMode.status === 'muted' ||
        this.voiceMode.status === 'paused' ||
        this.voiceMode.status === 'off'
      ) {
        return;
      }
      tick = (tick + 1) % 22;
      if (tick <= words.length + 1) {
        this.voiceMode = {
          status: 'listening',
          level: tick === 0 ? 0 : 0.2 + 0.7 * Math.abs(Math.sin(tick * 1.3)),
          partial: words.slice(0, Math.max(0, tick - 1)).join(' '),
        };
      } else if (tick <= words.length + 5) {
        this.voiceMode = {status: 'thinking'};
      } else {
        this.voiceMode = {status: 'speaking', level: 0};
      }
      this.emit();
    });
  }

  setMuted(muted: boolean): void {
    if (this.voiceMode.status !== 'off') {
      this.voiceMode = muted
        ? {status: 'muted'}
        : {status: 'listening', level: 0, partial: ''};
      this.emit();
    }
  }

  interrupt(): void {
    if (
      this.voiceMode.status === 'speaking' ||
      this.voiceMode.status === 'thinking'
    ) {
      this.voiceMode = {status: 'listening', level: 0, partial: ''};
      this.eventListeners.forEach(l =>
        l({type: 'barge_in', by: 'button', stopMs: 0}),
      );
      this.emit();
    }
  }

  async resumeVoiceMode(): Promise<void> {
    if (this.voiceMode.status === 'paused') {
      this.voiceMode = {status: 'listening', level: 0, partial: ''};
      this.emit();
    }
  }

  /** Dev only: what a phone call does. */
  pauseForCall(): void {
    if (this.voiceMode.status !== 'off') {
      this.voiceMode = {status: 'paused'};
      this.emit();
    }
  }

  stopVoiceMode(): void {
    this.clear();
    this.voiceMode = {status: 'off'};
    this.emit();
  }

  async setAudioOutput(): Promise<void> {}

  async setVoice(voiceId: string): Promise<void> {
    const option = this.voices.find(v => v.id === voiceId);
    if (!option) {
      throw new Error('unknown voice');
    }
    if (!option.installed) {
      for (const progress of [0.25, 0.5, 0.75, 1]) {
        this.eventListeners.forEach(l =>
          l({type: 'voice_download', voiceId, progress}),
        );
        await new Promise(resolve => setTimeout(resolve, this.stepMs));
      }
      this.voices = this.voices.map(v =>
        v.id === voiceId ? {...v, installed: true} : v,
      );
    }
    this.voiceId = voiceId;
    this.emit();
  }

  updateSettings(patch: Partial<VoiceSettings>): void {
    this.settings = {...this.settings, ...patch};
    this.emit();
  }

  async transcribeFile(): Promise<never> {
    throw new Error('not available in the demo');
  }
}
