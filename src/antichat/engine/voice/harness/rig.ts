/**
 * The whole voice-mode pipeline on a virtual clock, fed from the WAV
 * fixtures: microphone → turn detector → recogniser → chat → speaker, with
 * the speaker's output leaking back into the microphone as echo.
 *
 * Used by the Jest suites and by the latency model in `pipeline.test.ts`.
 */
import {mixPcm, samplesFor} from '../audio/pcm';
import {
  VoiceModeController,
  type VoiceModeConfig,
  type VoiceModeEvent,
} from '../mode/controller';
import type {VoiceChatPort} from '../mode/chatPort';
import type {SttAdapter} from '../stt/types';
import {WhisperSttAdapter} from '../stt/whisperAdapter';
import {
  DEFAULT_TTS_TIMINGS,
  FakeChat,
  FakeKeepAwake,
  FakeMic,
  FakeSession,
  FakeTts,
  OracleWhisper,
  VirtualClock,
  voicedSamples,
  withoutSpeculation,
  type FakeChatTimings,
  type FakeTtsTimings,
} from './fakes';
import {fixture, fixturePcm} from './fixtures';

export interface RigOptions {
  config?: Partial<VoiceModeConfig>;
  /** Echo cancellation reported by the audio session. */
  echoCancellation?: boolean;
  route?: 'speaker' | 'earpiece' | 'bluetooth' | 'wired';
  /**
   * How much of the speaker's output reaches the microphone, as a linear
   * gain on the `en-us-reply` fixture (0 = none; 0.05 ≈ -26 dB, what is left
   * after the phone's echo canceller; 1 = an open loudspeaker without one).
   */
  echoGain?: number;
  tts?: Partial<FakeTtsTimings>;
  chat?: Partial<FakeChatTimings>;
  /** Decode time of the recogniser for `audioMs` of audio. */
  sttDecodeMs?: (audioMs: number) => number;
  reply?: (userText: string) => string;
  /** Chat port without `speculate` (the feature is then off whatever the config says). */
  noSpeculation?: boolean;
  /** Another recogniser instead of the Whisper oracle. */
  stt?: (clock: VirtualClock) => SttAdapter;
  permission?: 'granted' | 'denied' | 'blocked';
}

const TICK_MS = 50;

export const DEFAULT_REPLY =
  'Paris is the capital of France. About two million people live in the city itself.';

export class VoiceRig {
  readonly clock = new VirtualClock();
  readonly mic = new FakeMic();
  readonly session: FakeSession;
  readonly keepAwake = new FakeKeepAwake();
  readonly whisper: OracleWhisper;
  readonly tts: FakeTts;
  readonly chat: FakeChat;
  readonly controller: VoiceModeController;
  readonly events: VoiceModeEvent[] = [];
  echoGain: number;
  private echoAt = 0;
  private readonly echoSource = fixturePcm('en-us-reply');

  constructor(options: RigOptions = {}) {
    this.session = new FakeSession({
      route: options.route ?? 'speaker',
      echoCancellation: options.echoCancellation ?? true,
    });
    this.echoGain = options.echoGain ?? 0.05;
    this.whisper = new OracleWhisper(this.clock);
    if (options.sttDecodeMs) {
      this.whisper.decodeMs = options.sttDecodeMs;
    }
    this.tts = new FakeTts(this.clock, {
      ...DEFAULT_TTS_TIMINGS,
      ...options.tts,
    });
    this.chat = new FakeChat(
      this.clock,
      options.reply ?? (() => DEFAULT_REPLY),
    );
    this.chat.timings = {...this.chat.timings, ...options.chat};
    const chat: VoiceChatPort = options.noSpeculation
      ? withoutSpeculation(this.chat)
      : this.chat;
    this.controller = new VoiceModeController(
      {
        session: this.session,
        mic: this.mic,
        stt: options.stt?.(this.clock) ?? new WhisperSttAdapter(this.whisper),
        tts: this.tts,
        chat,
        keepAwake: this.keepAwake,
        permission: {ensure: async () => options.permission ?? 'granted'},
        clock: this.clock,
      },
      options.config,
    );
    this.controller.events.on(event => this.events.push(event));
  }

  get phases(): string[] {
    return this.events.flatMap(e => (e.type === 'phase' ? [e.phase] : []));
  }

  of<T extends VoiceModeEvent['type']>(
    type: T,
  ): Extract<VoiceModeEvent, {type: T}>[] {
    return this.events.filter(
      (e): e is Extract<VoiceModeEvent, {type: T}> => e.type === type,
    );
  }

  async start(conversationId: string | null = null): Promise<void> {
    const starting = this.controller.start(conversationId);
    await this.clock.advance(TICK_MS);
    await starting;
  }

  /** One microphone chunk: the user's audio plus the speaker's echo, if any. */
  private tick(user: Int16Array | null): void {
    const size = samplesFor(TICK_MS);
    let chunk: Int16Array = user ?? new Int16Array(size);
    if (this.tts.playing && this.echoGain > 0) {
      if (this.echoAt + size > this.echoSource.length) {
        this.echoAt = 0;
      }
      const echo = this.echoSource.subarray(this.echoAt, this.echoAt + size);
      this.echoAt += size;
      chunk = mixPcm(chunk, echo, this.echoGain);
    }
    this.mic.emit(chunk);
  }

  /** Lets `ms` pass with the user silent. */
  async quiet(ms: number): Promise<void> {
    for (let t = 0; t < ms; t += TICK_MS) {
      this.tick(null);
      await this.clock.advance(TICK_MS);
    }
  }

  /** The user says a fixture, in real time. */
  async say(id: string, text = fixture(id).text): Promise<void> {
    const pcm = fixturePcm(id);
    this.whisper.current = {
      text,
      language: fixture(id).lang,
      voiced: voicedSamples(pcm),
    };
    const size = samplesFor(TICK_MS);
    for (let at = 0; at < pcm.length; at += size) {
      const chunk = new Int16Array(size);
      chunk.set(pcm.subarray(at, Math.min(pcm.length, at + size)));
      this.tick(chunk);
      await this.clock.advance(TICK_MS);
    }
  }

  /** Silence until the controller reaches `phase` (or `limitMs` passes). */
  async until(phase: string, limitMs = 30_000): Promise<boolean> {
    for (
      let t = 0;
      t < limitMs && this.controller.phase !== phase;
      t += TICK_MS
    ) {
      this.tick(null);
      await this.clock.advance(TICK_MS);
    }
    return this.controller.phase === phase;
  }

  /** One full turn: say it, wait for the answer to be spoken to the end. */
  async turn(id: string): Promise<void> {
    await this.say(id);
    await this.until('speaking');
    await this.until('listening');
  }
}
