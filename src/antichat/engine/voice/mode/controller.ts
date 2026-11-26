/**
 * Hands-free voice conversation: turn-based with barge-in.
 *
 * The controller owns one microphone stream and routes every chunk by phase:
 * while listening, into the turn detector and the recogniser; while the
 * assistant thinks or speaks, into the barge-in detector behind the echo
 * guard. A turn that ends is transcribed, sent through the normal chat path
 * (so it is committed to the thread) and the reply is spoken sentence by
 * sentence while it is generated.
 */
import {durationMs, meterLevel, rms, toDb} from '../audio/pcm';
import {LatencyTracker, type TurnLatency} from '../latency/tracker';
import type {
  AudioRoute,
  AudioSessionPort,
  KeepAwake,
  MicPermission,
  MicSource,
  SessionEvent,
} from '../session/ports';
import {sameWords} from '../stt/text';
import type {SttAdapter, SttSession} from '../stt/types';
import type {PronunciationLexicon} from '../tts/pronunciation';
import {StreamingSpeaker} from '../tts/streamingSpeaker';
import type {TtsBackend} from '../tts/types';
import {SYSTEM_VOICE, type CatalogVoice} from '../tts/voices';
import {
  Hub,
  systemClock,
  voiceError,
  type Clock,
  type VoiceError,
} from '../types';
import {EnergyVad} from '../vad/energyVad';
import {TurnDetector, type TurnEvent} from '../vad/turnDetector';
import type {
  SpeculativeReply,
  VoiceChatPort,
  VoiceReplyCallbacks,
  VoiceReplyResult,
} from './chatPort';
import {EchoGuard} from './echo';
import {transition, type VoiceMachineEvent, type VoicePhase} from './machine';

export interface VoiceModeDeps {
  session: AudioSessionPort;
  mic: MicSource;
  stt: SttAdapter;
  tts: TtsBackend;
  chat: VoiceChatPort;
  keepAwake?: KeepAwake;
  permission?: MicPermission;
  lexicon?: PronunciationLexicon;
  clock?: Clock;
}

export interface VoiceModeConfig {
  /** 'auto' or a BCP-47 tag. */
  language: string;
  voice: CatalogVoice;
  rate: number;
  /** Silence that ends the user's turn. */
  hangMs: number;
  /** Pause after which a provisional transcript starts the reply early; 0 = off. */
  speculativeMs: number;
  /** Speaking over the assistant stops it. */
  bargeIn: boolean;
  /** No speech for this long ends the session. */
  idleTimeoutMs: number;
  /** Loading models and opening the microphone may take this long. */
  startTimeoutMs: number;
  sttTimeoutMs: number;
  /** No first word from the model within this: the turn is dropped. */
  replyTimeoutMs: number;
  /** A microphone that delivers nothing for this long is restarted once. */
  micWatchdogMs: number;
  /** Failed turns in a row before the session gives up. */
  maxErrors: number;
}

export const DEFAULT_VOICE_MODE_CONFIG: VoiceModeConfig = {
  language: 'auto',
  voice: SYSTEM_VOICE,
  rate: 1,
  hangMs: 700,
  speculativeMs: 300,
  bargeIn: true,
  idleTimeoutMs: 180_000,
  startTimeoutMs: 45_000,
  sttTimeoutMs: 15_000,
  replyTimeoutMs: 30_000,
  micWatchdogMs: 3_000,
  maxErrors: 3,
};

export type VoiceStopReason =
  | 'user'
  | 'idle_timeout'
  | 'error'
  | 'mic_lost'
  | 'permission'
  | 'start_failed';

export type VoiceModeEvent =
  | {type: 'phase'; phase: VoicePhase; muted: boolean}
  /** Microphone (listening) level 0..1, a few times per second. */
  | {type: 'level'; level: number}
  /** Live transcript of the turn being spoken. */
  | {type: 'partial'; text: string}
  | {type: 'user_turn'; text: string}
  | {type: 'assistant_delta'; delta: string}
  | {
      type: 'assistant_done';
      status: VoiceReplyResult['status'] | 'interrupted';
      /** The part of the answer the user actually heard. */
      heardText: string;
    }
  | {type: 'conversation'; conversationId: string}
  | {type: 'barge_in'; detectMs: number; stopMs: number; by: 'voice' | 'button'}
  | {type: 'latency'; turn: TurnLatency}
  | {type: 'route'; route: AudioRoute; halfDuplex: boolean}
  | {type: 'voice_fallback'; voice: CatalogVoice}
  | {type: 'error'; error: VoiceError; stage: string; fatal: boolean}
  | {type: 'stopped'; reason: VoiceStopReason};

const withTimeout = <T>(
  clock: Clock,
  promise: Promise<T>,
  ms: number,
  what: string,
): Promise<T> =>
  new Promise<T>((resolve, reject) => {
    const timer = clock.setTimeout(
      () => reject(new Error(`${what} timed out after ${ms} ms`)),
      ms,
    );
    promise.then(
      value => {
        clock.clearTimeout(timer);
        resolve(value);
      },
      err => {
        clock.clearTimeout(timer);
        reject(err);
      },
    );
  });

export class VoiceModeController {
  readonly events = new Hub<VoiceModeEvent>();
  readonly latency = new LatencyTracker();
  private readonly clock: Clock;
  private config: VoiceModeConfig;
  private phaseValue: VoicePhase = 'off';
  private muted = false;
  private conversationId: string | null = null;

  /** Bumped whenever the running turn is superseded (barge-in, pause, stop). */
  private turnToken = 0;
  private detector!: TurnDetector;
  private bargeDetector!: TurnDetector;
  private guard = new EchoGuard({hardwareAec: false, route: 'unknown'});
  private sttSession: SttSession | null = null;
  private speaker: StreamingSpeaker | null = null;
  private speculation: SpeculativeReply | null = null;
  /** Counts pauses and resumptions, to tell a stale snapshot from a current one. */
  private pauseSeq = 0;
  private lastSpoken = '';
  private voice: CatalogVoice;

  private releaseAwake: (() => void) | null = null;
  private unsubscribeSession: (() => void) | null = null;
  private idleTimer: unknown = null;
  private watchdogTimer: unknown = null;
  private lastChunkAt = 0;
  private micRestarted = false;
  private lastLevelAt = 0;
  private errors = 0;
  private echoCancellation = false;

  constructor(
    private readonly deps: VoiceModeDeps,
    config: Partial<VoiceModeConfig> = {},
  ) {
    this.clock = deps.clock ?? systemClock;
    this.config = {...DEFAULT_VOICE_MODE_CONFIG, ...config};
    this.voice = this.config.voice;
    this.buildDetectors();
  }

  get phase(): VoicePhase {
    return this.phaseValue;
  }

  get isMuted(): boolean {
    return this.muted;
  }

  get activeConversationId(): string | null {
    return this.conversationId;
  }

  /** Applies to the next turn (voice, speed, language) or the next session. */
  configure(config: Partial<VoiceModeConfig>): void {
    this.config = {...this.config, ...config};
    if (config.voice) {
      this.voice = config.voice;
    }
  }

  async start(conversationId: string | null): Promise<void> {
    if (!this.step('START')) {
      return;
    }
    this.conversationId = conversationId;
    this.errors = 0;
    this.micRestarted = false;
    this.voice = this.config.voice;
    const token = ++this.turnToken;
    try {
      const permission = (await this.deps.permission?.ensure()) ?? 'granted';
      if (permission !== 'granted') {
        this.fail(
          voiceError('permission_denied', permission, false),
          'permission',
        );
        return;
      }
      await withTimeout(
        this.clock,
        (async () => {
          const info = await this.deps.session.activate('conversation');
          this.echoCancellation = info.echoCancellation;
          this.guard = new EchoGuard({
            hardwareAec: info.echoCancellation,
            route: info.route,
          });
          this.events.emit({
            type: 'route',
            route: info.route,
            halfDuplex: this.guard.halfDuplex,
          });
          await Promise.all([
            this.deps.stt.prepare(this.config.language),
            this.deps.tts.prepare(this.voice).catch(err => {
              // The chosen voice does not load: speak with the system voice.
              this.fallBackToSystemVoice(err);
            }),
          ]);
          if (token !== this.turnToken) {
            return;
          }
          await this.deps.mic.start(this.onChunk, {
            echoCancellation: info.echoCancellation,
          });
        })(),
        this.config.startTimeoutMs,
        'voice start',
      );
    } catch (err) {
      if (token === this.turnToken) {
        this.fail(voiceError('failed', err), 'start_failed');
      }
      return;
    }
    if (token !== this.turnToken) {
      return;
    }
    this.releaseAwake = this.deps.keepAwake?.acquire() ?? null;
    this.unsubscribeSession = this.deps.session.on(this.onSessionEvent);
    this.lastChunkAt = this.clock.now();
    this.armWatchdog();
    this.step('READY');
    this.beginListening();
  }

  async stop(reason: VoiceStopReason = 'user'): Promise<void> {
    if (this.phaseValue === 'off') {
      return;
    }
    this.turnToken++;
    this.step('STOP');
    this.clearTimers();
    this.cancelTurn();
    this.unsubscribeSession?.();
    this.unsubscribeSession = null;
    this.releaseAwake?.();
    this.releaseAwake = null;
    await this.deps.mic.stop().catch(() => {});
    await this.deps.session.deactivate().catch(() => {});
    this.events.emit({type: 'stopped', reason});
  }

  setMuted(muted: boolean): void {
    if (this.muted === muted) {
      return;
    }
    this.muted = muted;
    if (muted && this.phaseValue === 'listening') {
      // What was said so far is discarded, like covering the microphone.
      this.sttSession?.cancel();
      this.sttSession = null;
      this.cancelSpeculation();
    } else if (!muted && this.phaseValue === 'listening') {
      this.beginListening();
    }
    this.emitPhase();
  }

  /** The button: cut the answer short and listen again. */
  interrupt(): void {
    if (this.phaseValue === 'thinking' || this.phaseValue === 'speaking') {
      this.bargeIn('button', 0);
    }
  }

  /** After an interruption that did not resume by itself. */
  async resume(): Promise<void> {
    if (this.phaseValue !== 'paused') {
      return;
    }
    try {
      const info = await this.deps.session.activate('conversation');
      this.echoCancellation = info.echoCancellation;
      this.guard.setRoute(info.route, info.echoCancellation);
      await this.deps.mic.start(this.onChunk, {
        echoCancellation: info.echoCancellation,
      });
    } catch (err) {
      this.fail(voiceError('mic_unavailable', err), 'mic_lost');
      return;
    }
    this.lastChunkAt = this.clock.now();
    this.armWatchdog();
    if (this.step('INTERRUPTION_ENDED')) {
      this.beginListening();
    }
  }

  // ---------------------------------------------------------------- audio

  private onChunk = (pcm: Int16Array): void => {
    const now = this.clock.now();
    this.lastChunkAt = now;
    this.micRestarted = false;
    switch (this.phaseValue) {
      case 'listening':
        if (!this.muted) {
          this.listen(pcm);
        }
        break;
      case 'thinking':
      case 'speaking':
        if (!this.muted) {
          this.watchForBargeIn(pcm);
        }
        break;
      default:
        break;
    }
    if (now - this.lastLevelAt >= 100 && this.phaseValue === 'listening') {
      this.lastLevelAt = now;
      const db = this.detector.levelDb;
      this.events.emit({
        type: 'level',
        level: this.muted ? 0 : meterLevel(Math.pow(10, db / 20)),
      });
    }
  };

  private listen(pcm: Int16Array): void {
    const now = this.clock.now();
    // Our own voice may still be ringing right after the answer ended.
    if (this.guard.halfDuplex && this.guard.active(now)) {
      return;
    }
    this.detector.vad.setGateDb(this.guard.gateDb(now));
    this.sttSession?.push(pcm);
    for (const event of this.detector.push(pcm)) {
      this.onTurnEvent(event);
      if (this.phaseValue !== 'listening') {
        break;
      }
    }
  }

  private onTurnEvent(event: TurnEvent): void {
    switch (event.type) {
      case 'speech_start':
        this.latency.begin();
        this.armIdleTimer();
        break;
      case 'provisional':
        this.pauseSeq++;
        if (this.config.speculativeMs > 0 && this.deps.chat.speculate) {
          this.speculate();
        }
        break;
      case 'speech_resumed':
        this.pauseSeq++;
        this.cancelSpeculation();
        break;
      case 'endpoint': {
        const now = this.clock.now();
        // Audio time → wall time: the last voiced frame was this long ago.
        this.latency.mark(
          'speechEnd',
          now - (this.detector.nowMs - event.speechEndMs),
        );
        this.latency.mark('endpoint', now);
        this.detector.resetTurn();
        this.endTurn().catch(() => {});
        break;
      }
    }
  }

  private watchForBargeIn(pcm: Int16Array): void {
    if (!this.config.bargeIn || this.guard.halfDuplex) {
      return;
    }
    const now = this.clock.now();
    const detector = this.bargeDetector;
    detector.vad.setGateDb(this.guard.gateDb(now));
    const events = detector.push(pcm);
    this.guard.observe(toDb(rms(pcm)), now, durationMs(pcm.length));
    const start = events.find(e => e.type === 'speech_start');
    if (start && start.type === 'speech_start') {
      this.bargeIn('voice', detector.nowMs - start.onsetMs);
    }
  }

  // ----------------------------------------------------------------- turn

  private beginListening(preRoll?: Int16Array): void {
    this.detector.resetTurn();
    this.bargeDetector.resetTurn();
    this.cancelSpeculation();
    this.sttSession?.cancel();
    this.sttSession = this.muted
      ? null
      : this.deps.stt.start(
          {
            language: this.config.language,
            mode: 'conversation',
            punctuate: true,
          },
          event => {
            if (event.type === 'partial' && this.phaseValue === 'listening') {
              this.events.emit({type: 'partial', text: event.text});
            }
          },
        );
    this.armIdleTimer();
    if (preRoll?.length && !this.muted) {
      this.listen(preRoll);
    }
  }

  /** At the first short pause: transcribe what there is and start the reply. */
  private speculate(): void {
    const session = this.sttSession;
    const pause = this.pauseSeq;
    if (!session) {
      return;
    }
    session
      .snapshot()
      .then(text => {
        // Only if this is still the same pause of the same turn.
        const stillPaused =
          pause === this.pauseSeq &&
          session === this.sttSession &&
          !this.speculation;
        if (!stillPaused || !text.trim()) {
          return;
        }
        this.speculation = this.deps.chat.speculate!(text.trim(), {
          conversationId: this.conversationId,
          spoken: true,
        });
      })
      .catch(() => {});
  }

  private cancelSpeculation(): void {
    this.speculation?.cancel();
    this.speculation = null;
  }

  private async endTurn(): Promise<void> {
    const session = this.sttSession;
    this.sttSession = null;
    if (!session || !this.step('TURN_ENDED')) {
      return;
    }
    this.clearIdleTimer();
    const token = ++this.turnToken;
    const live = () => token === this.turnToken;

    let text = '';
    let language = '';
    try {
      const result = await withTimeout(
        this.clock,
        session.finish(),
        this.config.sttTimeoutMs,
        'transcription',
      );
      text = result.text.trim();
      language = result.language;
    } catch (err) {
      session.cancel();
      if (live()) {
        this.recover(voiceError('failed', err), 'stt');
      }
      return;
    }
    if (!live()) {
      return;
    }
    this.latency.mark('sttFinal', this.clock.now());
    // Layer 3 of the echo guard: the "user" repeated our last answer.
    const echo = text && EchoGuard.isEchoTranscript(text, this.lastSpoken);
    if (!text || echo) {
      this.cancelSpeculation();
      this.step('TURN_DROPPED');
      this.beginListening();
      return;
    }
    this.events.emit({type: 'user_turn', text});

    const speaker = new StreamingSpeaker(
      this.deps.tts,
      {
        voice: this.voice,
        rate: this.config.rate,
        language:
          this.config.language === 'auto'
            ? language || undefined
            : this.config.language,
      },
      {clock: this.clock, lexicon: this.deps.lexicon},
    );
    this.speaker = speaker;
    let speechFailed = false;
    speaker.events.on(event => {
      if (!live()) {
        return;
      }
      if (event.type === 'first_unit') {
        this.latency.mark('firstSentence', event.atMs);
      } else if (event.type === 'unit_start' && event.first) {
        this.latency.mark('firstAudio', event.atMs);
        this.guard.playbackStarted(event.atMs);
        this.bargeDetector.resetTurn();
        this.step('FIRST_AUDIO');
        const turn = this.latency.complete();
        if (turn) {
          this.events.emit({type: 'latency', turn});
        }
      } else if (event.type === 'error') {
        speechFailed = true;
        this.events.emit({
          type: 'error',
          error: event.error,
          stage: 'tts',
          fatal: false,
        });
        this.fallBackToSystemVoice(event.error.detail);
      }
    });

    let gotToken = false;
    const callbacks: VoiceReplyCallbacks = {
      onDelta: delta => {
        if (!live()) {
          return;
        }
        if (!gotToken) {
          gotToken = true;
          this.latency.mark('firstToken', this.clock.now());
        }
        speaker.push(delta);
        this.events.emit({type: 'assistant_delta', delta});
      },
      onMessages: ids => {
        if (live() && ids.conversationId !== this.conversationId) {
          this.conversationId = ids.conversationId;
          this.events.emit({
            type: 'conversation',
            conversationId: ids.conversationId,
          });
        }
      },
    };
    const options = {
      conversationId: this.conversationId,
      spoken: true as const,
      language: language || undefined,
    };
    const speculation = this.speculation;
    this.speculation = null;
    const adopted = !!speculation && sameWords(speculation.text, text);
    if (speculation && !adopted) {
      speculation.cancel();
    }
    this.latency.setSpeculation(
      this.config.speculativeMs > 0 && this.deps.chat.speculate
        ? adopted
          ? 'adopted'
          : speculation
            ? 'discarded'
            : 'none'
        : 'off',
    );
    const replyTimer = this.clock.setTimeout(() => {
      if (live() && !gotToken) {
        this.deps.chat.stop();
      }
    }, this.config.replyTimeoutMs);

    let result: VoiceReplyResult;
    try {
      result = adopted
        ? await speculation!.commit(callbacks)
        : await this.deps.chat.send(text, options, callbacks);
    } catch (err) {
      result = {
        status: 'error',
        conversationId: this.conversationId,
        detail: String(err instanceof Error ? err.message : err),
      };
    }
    this.clock.clearTimeout(replyTimer);
    if (!live()) {
      return;
    }
    if (
      result.conversationId &&
      result.conversationId !== this.conversationId
    ) {
      this.conversationId = result.conversationId;
      this.events.emit({
        type: 'conversation',
        conversationId: result.conversationId,
      });
    }
    if (
      result.status === 'error' ||
      (!gotToken && result.status === 'stopped')
    ) {
      await speaker.stop();
      if (live()) {
        this.speaker = null;
        this.recover(
          voiceError(
            result.status === 'error' ? 'failed' : 'timeout',
            result.detail ?? 'no reply',
          ),
          'reply',
        );
      }
      return;
    }
    await speaker.finish();
    if (!live()) {
      return;
    }
    this.guard.playbackStopped(this.clock.now());
    this.lastSpoken = speaker.spokenText;
    this.speaker = null;
    this.errors = speechFailed ? this.errors : 0;
    this.events.emit({
      type: 'assistant_done',
      status: result.status,
      heardText: speaker.heardText,
    });
    this.step('REPLY_DONE');
    this.beginListening();
  }

  private bargeIn(by: 'voice' | 'button', detectMs: number): void {
    if (!this.step('BARGE_IN')) {
      return;
    }
    const detectedAt = this.clock.now();
    this.turnToken++;
    const speaker = this.speaker;
    this.speaker = null;
    this.cancelSpeculation();
    this.deps.chat.stop();
    // The words that tripped the detector open the new turn.
    const preRoll = by === 'voice' ? this.bargeDetector.take() : undefined;
    if (speaker) {
      this.lastSpoken = speaker.spokenText;
      const heardText = speaker.heardText;
      speaker
        .stop()
        .then(() => {
          const stopMs = this.clock.now() - detectedAt;
          this.guard.playbackStopped(this.clock.now());
          this.latency.recordBargeIn({detectMs, stopMs});
          this.events.emit({type: 'barge_in', detectMs, stopMs, by});
          this.events.emit({
            type: 'assistant_done',
            status: 'interrupted',
            heardText,
          });
        })
        .catch(() => {});
    } else {
      this.events.emit({type: 'barge_in', detectMs, stopMs: 0, by});
    }
    this.beginListening(preRoll);
  }

  // --------------------------------------------------------------- system

  private onSessionEvent = (event: SessionEvent): void => {
    switch (event.type) {
      case 'interruption_began':
        if (this.step('INTERRUPTION_BEGAN')) {
          this.turnToken++;
          this.clearTimers();
          this.cancelTurn();
          this.deps.mic.stop().catch(() => {});
        }
        break;
      case 'interruption_ended':
        if (event.shouldResume) {
          this.resume().catch(() => {});
        }
        break;
      case 'route_changed':
        this.guard.setRoute(event.route, this.echoCancellation);
        this.events.emit({
          type: 'route',
          route: event.route,
          halfDuplex: this.guard.halfDuplex,
        });
        // Headphones pulled while the answer plays: do not carry on aloud.
        if (
          event.reason === 'device_removed' &&
          this.phaseValue === 'speaking'
        ) {
          this.bargeIn('button', 0);
        }
        break;
    }
  };

  private fallBackToSystemVoice(detail: unknown): void {
    if (this.voice.engine === 'system') {
      return;
    }
    this.voice = SYSTEM_VOICE;
    this.events.emit({type: 'voice_fallback', voice: SYSTEM_VOICE});
    this.events.emit({
      type: 'error',
      error: voiceError('failed', detail),
      stage: 'tts',
      fatal: false,
    });
  }

  /** A turn failed; listen again unless that keeps happening. */
  private recover(error: VoiceError, stage: string): void {
    this.errors++;
    const fatal = this.errors >= this.config.maxErrors;
    this.events.emit({type: 'error', error, stage, fatal});
    if (fatal) {
      this.stop('error').catch(() => {});
      return;
    }
    this.step('TURN_DROPPED');
    this.beginListening();
  }

  private fail(error: VoiceError, reason: VoiceStopReason): void {
    this.events.emit({type: 'error', error, stage: reason, fatal: true});
    this.stop(reason).catch(() => {});
  }

  private cancelTurn(): void {
    this.cancelSpeculation();
    this.sttSession?.cancel();
    this.sttSession = null;
    if (this.speaker) {
      this.deps.chat.stop();
      this.speaker.stop().catch(() => {});
      this.guard.playbackStopped(this.clock.now());
      this.speaker = null;
    }
  }

  private buildDetectors(): void {
    this.detector = new TurnDetector({
      vad: new EnergyVad(),
      hangMs: this.config.hangMs,
      provisionalMs: this.config.speculativeMs,
      keepAudio: false,
    });
    this.bargeDetector = new TurnDetector({
      vad: new EnergyVad(),
      minSpeechMs: 300,
      preRollMs: 600,
      // Never ends by itself: only its speech start matters.
      hangMs: 3_600_000,
    });
  }

  private step(event: VoiceMachineEvent): boolean {
    const next = transition(this.phaseValue, event);
    if (!next) {
      return false;
    }
    if (next !== this.phaseValue) {
      this.phaseValue = next;
      this.emitPhase();
    }
    return true;
  }

  private emitPhase(): void {
    this.events.emit({
      type: 'phase',
      phase: this.phaseValue,
      muted: this.muted,
    });
  }

  private armIdleTimer(): void {
    this.clearIdleTimer();
    this.idleTimer = this.clock.setTimeout(() => {
      if (this.phaseValue === 'listening') {
        this.stop('idle_timeout').catch(() => {});
      }
    }, this.config.idleTimeoutMs);
  }

  private clearIdleTimer(): void {
    if (this.idleTimer !== null) {
      this.clock.clearTimeout(this.idleTimer);
      this.idleTimer = null;
    }
  }

  private armWatchdog(): void {
    if (this.watchdogTimer !== null) {
      this.clock.clearTimeout(this.watchdogTimer);
    }
    this.watchdogTimer = this.clock.setTimeout(() => {
      this.watchdogTimer = null;
      const phase = this.phaseValue;
      if (phase === 'off' || phase === 'paused' || phase === 'starting') {
        return;
      }
      if (this.clock.now() - this.lastChunkAt >= this.config.micWatchdogMs) {
        if (this.micRestarted) {
          this.fail(
            voiceError('mic_unavailable', 'no audio from the microphone'),
            'mic_lost',
          );
          return;
        }
        this.micRestarted = true;
        this.deps.mic
          .stop()
          .catch(() => {})
          .then(() =>
            this.deps.mic.start(this.onChunk, {
              echoCancellation: this.echoCancellation,
            }),
          )
          .catch(err =>
            this.fail(voiceError('mic_unavailable', err), 'mic_lost'),
          );
      }
      this.armWatchdog();
    }, this.config.micWatchdogMs);
  }

  private clearTimers(): void {
    this.clearIdleTimer();
    if (this.watchdogTimer !== null) {
      this.clock.clearTimeout(this.watchdogTimer);
      this.watchdogTimer = null;
    }
  }
}
