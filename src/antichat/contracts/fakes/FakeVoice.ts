import {Emitter} from '../common';
import type {
  DictationState,
  SpeechState,
  VoiceModeState,
  VoiceOption,
  VoicePort,
} from '../voice';

const PHRASE = 'What should I cook tonight with what is in the fridge';

/** Dictation that "hears" a phrase word by word; speech that plays to the end. */
export class FakeVoice extends Emitter implements VoicePort {
  dictation: DictationState = {status: 'idle'};
  speech: SpeechState = {status: 'idle'};
  voiceMode: VoiceModeState = {status: 'off'};
  voices: VoiceOption[] = [
    {id: 'voice-a', displayName: 'Juniper', languageTag: 'en-US'},
    {id: 'voice-b', displayName: 'Alder', languageTag: 'en-GB'},
  ];
  voiceId: string | null = 'voice-a';

  private timer?: ReturnType<typeof setInterval>;

  constructor(private readonly wordMs = 220) {
    super();
  }

  async startDictation(): Promise<void> {
    const words = PHRASE.split(' ');
    const startedAt = Date.now();
    let count = 0;
    this.dictation = {status: 'listening', partial: '', level: 0, startedAt};
    this.emit();
    this.timer = setInterval(() => {
      count = Math.min(words.length, count + 1);
      this.dictation = {
        status: 'listening',
        partial: words.slice(0, count).join(' '),
        level: 0.3 + 0.5 * Math.abs(Math.sin(count)),
        startedAt,
      };
      this.emit();
    }, this.wordMs);
  }

  async finishDictation(): Promise<string> {
    clearInterval(this.timer);
    const text =
      this.dictation.status === 'listening' ? this.dictation.partial : '';
    this.dictation = {status: 'idle'};
    this.emit();
    return text;
  }

  cancelDictation(): void {
    clearInterval(this.timer);
    this.dictation = {status: 'idle'};
    this.emit();
  }

  async speak(messageId: string, _text: string): Promise<void> {
    this.speech = {status: 'speaking', messageId, progress: 0};
    this.emit();
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
    this.speech = {status: 'idle'};
    this.emit();
  }

  async startVoiceMode(_conversationId: string | null): Promise<void> {
    this.voiceMode = {status: 'listening', level: 0.4};
    this.emit();
  }

  setMuted(muted: boolean): void {
    if (this.voiceMode.status !== 'off') {
      this.voiceMode = muted
        ? {status: 'muted'}
        : {status: 'listening', level: 0.4};
      this.emit();
    }
  }

  interrupt(): void {
    if (this.voiceMode.status === 'speaking') {
      this.voiceMode = {status: 'listening', level: 0.4};
      this.emit();
    }
  }

  stopVoiceMode(): void {
    this.voiceMode = {status: 'off'};
    this.emit();
  }

  async setVoice(voiceId: string): Promise<void> {
    this.voiceId = voiceId;
    this.emit();
  }
}
