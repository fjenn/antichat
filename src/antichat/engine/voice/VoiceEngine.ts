/**
 * The VoicePort implementation: one object that owns dictation, read-aloud
 * and voice mode, and makes sure only one of them holds the microphone and
 * the speaker at a time.
 */
import {meterLevel, rms} from './audio/pcm';
import {VoiceModeController, type VoiceModeConfig} from './mode/controller';
import type {VoiceChatPort} from './mode/chatPort';
import type {
  DictationState,
  SpeechState,
  VoiceModeState,
  VoiceOption,
  VoicePort,
  VoicePortEvent,
  VoiceSettings,
} from './port';
import type {
  AudioSessionPort,
  KeepAwake,
  MicPermission,
  MicSource,
} from './session/ports';
import {
  transcribeAudioFile,
  type AudioFileDecoder,
  type FileTranscript,
} from './stt/fileTranscriber';
import type {SttAdapter, SttSession} from './stt/types';
import {normalizeForSpeech} from './tts/normalize';
import {PronunciationLexicon} from './tts/pronunciation';
import {ReadAloudPlayer, type PlaybackKeeper} from './tts/readAloud';
import type {TtsBackend} from './tts/types';
import {
  SYSTEM_VOICE,
  TTS_ENGINES,
  defaultVoice,
  findVoice,
  voicesFor,
  type CatalogVoice,
  type TtsEngineId,
  type VoiceFacts,
} from './tts/voices';
import {
  Hub,
  systemClock,
  voiceError,
  type Clock,
  type Unsubscribe,
  type VoiceError,
} from './types';

export interface VoiceEngineDeps {
  /** The recogniser chosen for this phone (`selectStt`). */
  stt: SttAdapter;
  tts: TtsBackend;
  session: AudioSessionPort;
  mic: MicSource;
  chat: VoiceChatPort;
  keepAwake?: KeepAwake;
  permission?: MicPermission;
  keeper?: PlaybackKeeper;
  decoder?: AudioFileDecoder;
  clock?: Clock;
  /** Device class, platform, what is installed: decides voices and defaults. */
  facts: () => Omit<VoiceFacts, 'language'> & {language?: string};
  /** Downloads a voice engine's files; resolves when installed. */
  installEngine?: (
    engine: TtsEngineId,
    onProgress: (p: number) => void,
  ) => Promise<void>;
  /** False where the memory plan refuses hands-free mode. */
  voiceModeAvailable?: boolean;
  /** From the memory plan: unload the recogniser this long after use. */
  dictationWarmMs?: number;
  voiceWarmMs?: number;
  initial?: {
    voiceId?: string | null;
    rate?: number;
    settings?: Partial<VoiceSettings>;
  };
  /** Called when a setting changes, to persist it. */
  onPersist?: (state: {
    voiceId: string | null;
    rate: number;
    settings: VoiceSettings;
  }) => void;
  voiceMode?: Partial<VoiceModeConfig>;
}

const DEFAULT_SETTINGS: VoiceSettings = {
  language: 'auto',
  punctuation: true,
  fastReplies: true,
  bargeIn: true,
  pronunciations: [],
};

export class VoiceEngine implements VoicePort {
  dictation: DictationState = {status: 'idle'};
  speech: SpeechState = {status: 'idle'};
  voiceMode: VoiceModeState = {status: 'off'};
  voiceId: string | null;
  settings: VoiceSettings;

  private readonly listeners = new Set<() => void>();
  private readonly portEvents = new Hub<VoicePortEvent>();
  private readonly clock: Clock;
  private readonly lexicon: PronunciationLexicon;
  private readonly player: ReadAloudPlayer;
  private readonly controller: VoiceModeController;
  private rate: number;
  private dictationSession: SttSession | null = null;
  private dictationToken = 0;
  private releaseAwake: (() => void) | null = null;
  private sttWarmTimer: unknown = null;
  private ttsWarmTimer: unknown = null;
  private modeLevel = 0;
  private modePartial = '';

  constructor(private readonly deps: VoiceEngineDeps) {
    this.clock = deps.clock ?? systemClock;
    this.settings = {...DEFAULT_SETTINGS, ...deps.initial?.settings};
    this.voiceId = deps.initial?.voiceId ?? null;
    this.rate = deps.initial?.rate ?? 1;
    this.lexicon = new PronunciationLexicon(this.settings.pronunciations);

    this.player = new ReadAloudPlayer({
      backend: deps.tts,
      keeper: deps.keeper,
      lexicon: this.lexicon,
      voice: () => this.currentVoice(),
    });
    this.player.setRate(this.rate);
    this.player.changes.on(() => this.syncSpeech());
    this.player.errors.on(error =>
      this.portEvents.emit({
        type: 'error',
        scope: 'speech',
        error,
        fatal: false,
      }),
    );

    this.controller = new VoiceModeController(
      {
        session: deps.session,
        mic: deps.mic,
        stt: deps.stt,
        tts: deps.tts,
        chat: deps.chat,
        keepAwake: deps.keepAwake,
        permission: deps.permission,
        lexicon: this.lexicon,
        clock: this.clock,
      },
      deps.voiceMode,
    );
    this.controller.events.on(event => {
      switch (event.type) {
        case 'phase':
          if (event.phase !== 'listening') {
            this.modePartial = '';
          }
          this.syncVoiceMode();
          break;
        case 'level':
          this.modeLevel = event.level;
          this.syncVoiceMode();
          break;
        case 'partial':
          this.modePartial = event.text;
          this.syncVoiceMode();
          break;
        case 'user_turn':
          this.modePartial = '';
          this.portEvents.emit({
            type: 'user_turn',
            conversationId: this.controller.activeConversationId,
            text: event.text,
          });
          break;
        case 'assistant_done':
          this.portEvents.emit({
            type: 'assistant_turn',
            status: event.status,
            heardText: event.heardText,
          });
          break;
        case 'conversation':
          this.portEvents.emit(event);
          break;
        case 'barge_in':
          this.portEvents.emit({
            type: 'barge_in',
            by: event.by,
            stopMs: event.stopMs,
          });
          break;
        case 'latency':
        case 'route':
          this.portEvents.emit(event);
          break;
        case 'error':
          this.portEvents.emit({
            type: 'error',
            scope: 'voice_mode',
            error: event.error,
            fatal: event.fatal,
          });
          break;
        case 'stopped':
          this.portEvents.emit({
            type: 'voice_mode_stopped',
            reason: event.reason,
          });
          this.scheduleRelease();
          break;
        default:
          break;
      }
    });
  }

  // ------------------------------------------------------------ observing

  subscribe = (listener: () => void): Unsubscribe => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };

  onEvent = (listener: (event: VoicePortEvent) => void): Unsubscribe =>
    this.portEvents.on(listener);

  get voiceModeAvailable(): boolean {
    return this.deps.voiceModeAvailable ?? true;
  }

  get latency() {
    return this.controller.latency.turns.length
      ? this.controller.latency.summary()
      : null;
  }

  get activeVoiceId(): string {
    return this.currentVoice().id;
  }

  get voices(): readonly VoiceOption[] {
    const facts = this.voiceFacts();
    const recommended = voicesFor(facts)[0]?.id ?? SYSTEM_VOICE.id;
    return voicesFor(facts).map(voice => ({
      id: voice.id,
      displayName: voice.displayName,
      languageTag: voice.languageTag,
      gender: voice.gender,
      installed:
        voice.engine === 'system' ||
        facts.installedEngines.includes(voice.engine),
      downloadBytes: TTS_ENGINES[voice.engine].downloadBytes[facts.platform],
      recommended: voice.id === recommended,
    }));
  }

  // ------------------------------------------------------------ dictation

  async startDictation(): Promise<void> {
    if (
      this.dictation.status !== 'idle' &&
      this.dictation.status !== 'failed'
    ) {
      return;
    }
    if (this.controller.phase !== 'off') {
      return;
    }
    const token = ++this.dictationToken;
    const live = () => token === this.dictationToken;
    this.setDictation({status: 'starting'});
    await this.player.stop();
    this.cancelRelease('stt');
    try {
      const permission = (await this.deps.permission?.ensure()) ?? 'granted';
      if (permission !== 'granted') {
        throw voiceError('permission_denied', permission, false);
      }
      await this.deps.session.activate('dictation');
      try {
        await this.deps.stt.prepare(this.settings.language);
      } catch (err) {
        // Not the microphone's fault: the recogniser could not be loaded.
        throw isVoiceError(err) ? err : voiceError('failed', err);
      }
      if (!live()) {
        return;
      }
      let stable = '';
      const session = this.deps.stt.start(
        {
          language: this.settings.language,
          mode: 'dictation',
          punctuate: this.settings.punctuation,
        },
        event => {
          if (!live()) {
            return;
          }
          if (event.type === 'partial') {
            stable = event.stable;
          } else if (event.type === 'error') {
            this.portEvents.emit({
              type: 'error',
              scope: 'dictation',
              error: event.error,
              fatal: false,
            });
            return;
          }
          const state = this.dictation;
          if (state.status === 'listening') {
            const partial = session.text;
            // Final segments are settled; in the open one, the agreed words.
            const open = event.type === 'partial' ? event.text.length : 0;
            this.setDictation({
              ...state,
              partial,
              stableLength: partial.length - open + (open ? stable.length : 0),
            });
          }
        },
      );
      this.dictationSession = session;
      const startedAt = this.clock.now();
      let lastLevelAt = 0;
      this.setDictation({
        status: 'listening',
        partial: '',
        stableLength: 0,
        level: 0,
        startedAt,
      });
      this.releaseAwake = this.deps.keepAwake?.acquire() ?? null;
      await this.deps.mic.start(
        pcm => {
          if (!live()) {
            return;
          }
          session.push(pcm);
          const now = this.clock.now();
          const state = this.dictation;
          if (now - lastLevelAt >= 80 && state.status === 'listening') {
            lastLevelAt = now;
            this.setDictation({...state, level: meterLevel(rms(pcm))});
          }
        },
        {echoCancellation: false},
      );
    } catch (err) {
      if (live()) {
        await this.endDictationCapture();
        this.dictationSession?.cancel();
        this.dictationSession = null;
        this.setDictation({
          status: 'failed',
          error: isVoiceError(err) ? err : voiceError('mic_unavailable', err),
        });
      }
    }
  }

  async finishDictation(): Promise<string> {
    const session = this.dictationSession;
    if (!session || this.dictation.status !== 'listening') {
      return '';
    }
    const token = this.dictationToken;
    this.dictationSession = null;
    this.setDictation({status: 'transcribing'});
    await this.endDictationCapture();
    try {
      const result = await session.finish();
      if (token === this.dictationToken) {
        this.setDictation({status: 'idle'});
      }
      return result.text;
    } catch (err) {
      if (token === this.dictationToken) {
        this.setDictation({status: 'failed', error: voiceError('failed', err)});
      }
      return '';
    } finally {
      this.scheduleRelease();
    }
  }

  cancelDictation(): void {
    this.dictationToken++;
    this.dictationSession?.cancel();
    this.dictationSession = null;
    this.endDictationCapture().catch(() => {});
    this.setDictation({status: 'idle'});
    this.scheduleRelease();
  }

  private async endDictationCapture(): Promise<void> {
    this.releaseAwake?.();
    this.releaseAwake = null;
    await this.deps.mic.stop().catch(() => {});
    await this.deps.session.deactivate().catch(() => {});
  }

  // ----------------------------------------------------------- read aloud

  async speak(messageId: string, text: string): Promise<void> {
    if (this.controller.phase !== 'off') {
      return;
    }
    if (
      this.dictation.status === 'listening' ||
      this.dictation.status === 'starting'
    ) {
      this.cancelDictation();
    }
    this.cancelRelease('tts');
    await this.deps.session.activate('playback').catch(() => {});
    await this.player.play(messageId, text, {language: this.textLanguage()});
  }

  pauseSpeech(): void {
    this.player.pause();
  }

  resumeSpeech(): void {
    this.player.resume();
  }

  stopSpeech(): void {
    this.player.stop().catch(() => {});
  }

  seekSpeech(sentence: number): void {
    this.player.seekTo(sentence);
  }

  skipSpeech(direction: -1 | 1): void {
    if (direction < 0) {
      this.player.previous();
    } else {
      this.player.next();
    }
  }

  setSpeechRate(rate: number): void {
    this.rate = Math.max(0.5, Math.min(2, rate));
    this.player.setRate(this.rate);
    this.controller.configure({rate: this.rate});
    this.persist();
    this.syncSpeech();
  }

  async pronounce(text: string, languageTag?: string): Promise<void> {
    if (this.controller.phase !== 'off') {
      return;
    }
    const language = languageTag ?? this.textLanguage();
    const spoken = this.lexicon.apply(
      normalizeForSpeech(text, {language}),
      language,
    );
    if (!spoken) {
      return;
    }
    await this.player.stop();
    const stream = this.deps.tts.open(
      {
        voice: this.currentVoice(language),
        rate: Math.min(this.rate, 1),
        language,
      },
      {
        onUnitStart: () => {},
        onUnitEnd: () => {},
        onError: error =>
          this.portEvents.emit({
            type: 'error',
            scope: 'speech',
            error,
            fatal: false,
          }),
      },
    );
    stream.enqueue(0, spoken);
    await stream.end();
  }

  // ----------------------------------------------------------- voice mode

  async startVoiceMode(conversationId: string | null): Promise<void> {
    if (!this.voiceModeAvailable || this.controller.phase !== 'off') {
      return;
    }
    if (this.dictation.status !== 'idle') {
      this.cancelDictation();
    }
    await this.player.stop();
    this.cancelRelease('stt');
    this.cancelRelease('tts');
    this.modePartial = '';
    this.controller.configure({
      language: this.settings.language,
      voice: this.currentVoice(),
      rate: this.rate,
      bargeIn: this.settings.bargeIn,
      speculativeMs: this.settings.fastReplies
        ? (this.deps.voiceMode?.speculativeMs ?? 300)
        : 0,
    });
    await this.controller.start(conversationId);
  }

  setMuted(muted: boolean): void {
    this.controller.setMuted(muted);
  }

  interrupt(): void {
    this.controller.interrupt();
  }

  resumeVoiceMode(): Promise<void> {
    return this.controller.resume();
  }

  stopVoiceMode(): void {
    this.controller.stop('user').catch(() => {});
  }

  async setAudioOutput(output: 'speaker' | 'earpiece' | 'auto'): Promise<void> {
    const info = await this.deps.session.setOutput(output);
    this.portEvents.emit({
      type: 'route',
      route: info.route,
      halfDuplex: !info.echoCancellation && info.route === 'speaker',
    });
  }

  // ------------------------------------------------------------- settings

  async setVoice(voiceId: string): Promise<void> {
    const voice = findVoice(voiceId);
    if (!voice) {
      throw new Error(`unknown voice ${voiceId}`);
    }
    const facts = this.voiceFacts();
    if (
      voice.engine !== 'system' &&
      !facts.installedEngines.includes(voice.engine)
    ) {
      if (!this.deps.installEngine) {
        throw new Error(`voice ${voiceId} is not installed`);
      }
      await this.deps.installEngine(voice.engine, progress =>
        this.portEvents.emit({type: 'voice_download', voiceId, progress}),
      );
    }
    this.voiceId = voiceId;
    this.controller.configure({voice});
    this.persist();
    this.emit();
  }

  updateSettings(patch: Partial<VoiceSettings>): void {
    this.settings = {...this.settings, ...patch};
    if (patch.pronunciations) {
      this.lexicon.setUserEntries(patch.pronunciations);
    }
    this.persist();
    this.emit();
  }

  async transcribeFile(
    uri: string,
    onProgress?: (fraction: number, textSoFar: string) => void,
  ): Promise<FileTranscript> {
    if (!this.deps.decoder) {
      throw new Error('no audio decoder in this build');
    }
    this.cancelRelease('stt');
    try {
      await this.deps.stt.prepare(this.settings.language);
      return await transcribeAudioFile(uri, this.deps.decoder, this.deps.stt, {
        language: this.settings.language,
        onProgress,
      });
    } finally {
      this.scheduleRelease();
    }
  }

  // -------------------------------------------------------------- private

  private voiceFacts(): VoiceFacts {
    const facts = this.deps.facts();
    return {...facts, language: facts.language ?? this.textLanguage() ?? 'en'};
  }

  /** The language voices should speak: the fixed setting, else the phone's. */
  private textLanguage(): string | undefined {
    return this.settings.language === 'auto'
      ? this.deps.facts().language
      : this.settings.language;
  }

  /** The chosen voice if it can speak now, else the best installed one. */
  private currentVoice(language?: string): CatalogVoice {
    const facts = {...this.voiceFacts(), ...(language ? {language} : {})};
    const chosen = findVoice(this.voiceId);
    const usable =
      chosen &&
      voicesFor(facts).some(v => v.id === chosen.id) &&
      (chosen.engine === 'system' ||
        facts.installedEngines.includes(chosen.engine));
    return usable ? chosen : defaultVoice(facts).voice;
  }

  private syncSpeech(): void {
    const state = this.player.state;
    if (state.status === 'idle' || state.status === 'preparing') {
      if (state.status === 'idle' && this.speech.status !== 'idle') {
        this.deps.session.deactivate().catch(() => {});
        this.scheduleRelease();
      }
      this.speech = state;
    } else {
      const unit = this.player.sentences[state.index];
      this.speech = {
        status: state.status,
        messageId: state.messageId,
        progress: state.progress,
        sentence: state.index,
        sentenceCount: state.count,
        range: unit ? {start: unit.start, end: unit.end} : null,
        rate: this.rate,
      };
    }
    this.emit();
  }

  private syncVoiceMode(): void {
    const phase = this.controller.phase;
    switch (phase) {
      case 'off':
        this.voiceMode = {status: 'off'};
        break;
      case 'starting':
        this.voiceMode = {status: 'starting'};
        break;
      case 'listening':
        this.voiceMode = this.controller.isMuted
          ? {status: 'muted'}
          : {
              status: 'listening',
              level: this.modeLevel,
              partial: this.modePartial,
            };
        break;
      case 'thinking':
        this.voiceMode = {status: 'thinking'};
        break;
      case 'speaking':
        this.voiceMode = {status: 'speaking', level: 0};
        break;
      case 'paused':
        this.voiceMode = {status: 'paused'};
        break;
    }
    this.emit();
  }

  private setDictation(state: DictationState): void {
    this.dictation = state;
    this.emit();
  }

  /** Unloads speech models once they have been idle for the planned time. */
  private scheduleRelease(): void {
    const idle = () =>
      this.controller.phase === 'off' &&
      this.dictation.status !== 'listening' &&
      this.dictation.status !== 'starting' &&
      this.dictation.status !== 'transcribing';
    this.cancelRelease('stt');
    this.sttWarmTimer = this.clock.setTimeout(() => {
      this.sttWarmTimer = null;
      if (idle()) {
        this.deps.stt.release().catch(() => {});
      }
    }, this.deps.dictationWarmMs ?? 0);
    this.cancelRelease('tts');
    this.ttsWarmTimer = this.clock.setTimeout(() => {
      this.ttsWarmTimer = null;
      if (idle() && this.player.state.status === 'idle') {
        this.deps.tts.release().catch(() => {});
      }
    }, this.deps.voiceWarmMs ?? 0);
  }

  private cancelRelease(which: 'stt' | 'tts'): void {
    const key = which === 'stt' ? 'sttWarmTimer' : 'ttsWarmTimer';
    if (this[key] !== null) {
      this.clock.clearTimeout(this[key]);
      this[key] = null;
    }
  }

  private persist(): void {
    this.deps.onPersist?.({
      voiceId: this.voiceId,
      rate: this.rate,
      settings: this.settings,
    });
  }

  private emit(): void {
    this.listeners.forEach(listener => listener());
  }
}

const isVoiceError = (value: unknown): value is VoiceError =>
  typeof value === 'object' &&
  value !== null &&
  'code' in value &&
  'retryable' in value;
