/**
 * Stand-ins for the phone, driven by a virtual clock: a microphone fed from
 * PCM buffers, an audio session, a voice that takes time to start and to
 * speak, a chat model that streams words, and a recogniser with a decode
 * time. They let the whole voice pipeline run in Jest (and time itself)
 * without native modules.
 */
import {chunked, durationMs, rms} from '../audio/pcm';
import type {
  SpeculativeReply,
  VoiceChatPort,
  VoiceReplyCallbacks,
  VoiceReplyResult,
  VoiceSendOptions,
} from '../mode/chatPort';
import type {
  AudioRoute,
  AudioSessionPort,
  KeepAwake,
  MicSource,
  SessionEvent,
  SessionInfo,
  SessionProfile,
} from '../session/ports';
import type {WhisperBackend} from '../stt/whisperAdapter';
import type {
  SystemRecognizerBackend,
  SystemRecognizerEvent,
  SystemRecognizerSupport,
  SystemRecognizerTask,
} from '../stt/systemAdapter';
import type {
  TtsBackend,
  TtsStream,
  TtsStreamCallbacks,
  TtsStreamOptions,
} from '../tts/types';
import type {CatalogVoice} from '../tts/voices';
import {voiceError, type Clock} from '../types';

/** Manual time. `advance` runs due timers in order; promises settle between steps. */
export class VirtualClock implements Clock {
  private time = 0;
  private seq = 0;
  private timers = new Map<number, {at: number; fn: () => void}>();

  now = (): number => this.time;

  setTimeout = (fn: () => void, ms: number): unknown => {
    const id = ++this.seq;
    this.timers.set(id, {at: this.time + Math.max(0, ms), fn});
    return id;
  };

  clearTimeout = (handle: unknown): void => {
    this.timers.delete(handle as number);
  };

  sleep = (ms: number): Promise<void> =>
    new Promise(resolve => this.setTimeout(resolve, ms));

  /** Moves time forward, firing timers and letting async work run. */
  async advance(ms: number): Promise<void> {
    const target = this.time + ms;
    for (;;) {
      await flushPromises();
      let next: {id: number; at: number; fn: () => void} | null = null;
      for (const [id, timer] of this.timers) {
        if (timer.at <= target && (!next || timer.at < next.at)) {
          next = {id, ...timer};
        }
      }
      if (!next) {
        break;
      }
      this.timers.delete(next.id);
      this.time = Math.max(this.time, next.at);
      next.fn();
    }
    this.time = target;
    await flushPromises();
  }
}

export async function flushPromises(rounds = 12): Promise<void> {
  for (let i = 0; i < rounds; i++) {
    await Promise.resolve();
  }
}

export class FakeMic implements MicSource {
  started = 0;
  stopped = 0;
  running = false;
  /** When true, `start` succeeds but no audio ever arrives. */
  dead = false;
  options: {echoCancellation: boolean} | null = null;
  private onChunk: ((pcm: Int16Array) => void) | null = null;

  async start(
    onChunk: (pcm: Int16Array) => void,
    options: {echoCancellation: boolean},
  ): Promise<void> {
    this.started++;
    this.running = true;
    this.options = options;
    this.onChunk = onChunk;
  }

  async stop(): Promise<void> {
    this.stopped++;
    this.running = false;
    this.onChunk = null;
  }

  emit(pcm: Int16Array): void {
    if (!this.dead) {
      this.onChunk?.(pcm);
    }
  }
}

export class FakeSession implements AudioSessionPort {
  profile: SessionProfile | null = null;
  activations: SessionProfile[] = [];
  info: SessionInfo;
  private listeners = new Set<(event: SessionEvent) => void>();

  constructor(info: Partial<SessionInfo> = {}) {
    this.info = {route: 'speaker', echoCancellation: true, ...info};
  }

  async activate(profile: SessionProfile): Promise<SessionInfo> {
    this.profile = profile;
    this.activations.push(profile);
    return this.info;
  }

  async deactivate(): Promise<void> {
    this.profile = null;
  }

  async setOutput(
    output: 'speaker' | 'earpiece' | 'auto',
  ): Promise<SessionInfo> {
    this.info = {...this.info, route: output === 'auto' ? 'speaker' : output};
    return this.info;
  }

  on(listener: (event: SessionEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  fire(event: SessionEvent): void {
    this.listeners.forEach(listener => listener(event));
  }

  changeRoute(
    route: AudioRoute,
    reason: 'new_device' | 'device_removed' | 'other',
  ): void {
    this.info = {...this.info, route};
    this.fire({type: 'route_changed', route, reason});
  }
}

export class FakeKeepAwake implements KeepAwake {
  holds = 0;
  acquire(): () => void {
    this.holds++;
    let released = false;
    return () => {
      if (!released) {
        released = true;
        this.holds--;
      }
    };
  }
}

export interface FakeTtsTimings {
  /** Loading the engine. */
  prepareMs: number;
  /** Synthesis before the first audio of a stream. */
  firstAudioMs: number;
  /** Gap before each later unit (0 when synthesis runs ahead). */
  gapMs: number;
  /** Playback time per character at rate 1. */
  msPerChar: number;
  /** How long `stop()` takes to silence the speaker. */
  stopMs: number;
}

export const DEFAULT_TTS_TIMINGS: FakeTtsTimings = {
  prepareMs: 0,
  firstAudioMs: 180,
  gapMs: 0,
  msPerChar: 60,
  stopMs: 40,
};

/** A voice on the virtual clock. Records what it said, in order. */
export class FakeTts implements TtsBackend {
  readonly log: {
    id: number;
    text: string;
    voice: string;
    rate: number;
    startedAt: number;
    endedAt?: number;
  }[] = [];
  prepared: string[] = [];
  released = 0;
  streams = 0;
  /** Voices whose engine fails to load / to speak. */
  failPrepare = new Set<string>();
  failSpeak = new Set<string>();
  /** True while audio is coming out. */
  playing = false;

  constructor(
    private readonly clock: VirtualClock,
    public timings: FakeTtsTimings = DEFAULT_TTS_TIMINGS,
  ) {}

  async prepare(voice: CatalogVoice): Promise<void> {
    await this.clock.sleep(this.timings.prepareMs);
    if (this.failPrepare.has(voice.engine)) {
      throw new Error(`engine ${voice.engine} failed to load`);
    }
    this.prepared.push(voice.id);
  }

  async release(): Promise<void> {
    this.released++;
  }

  open(options: TtsStreamOptions, callbacks: TtsStreamCallbacks): TtsStream {
    this.streams++;
    const {clock, timings} = this;
    const queue: {id: number; text: string}[] = [];
    let running = false;
    let stopped = false;
    let paused = false;
    let ended = false;
    let first = true;
    let resumeWaiters: (() => void)[] = [];
    const waiter: {resolve: (() => void) | null} = {resolve: null};

    const pump = async () => {
      if (running) {
        return;
      }
      running = true;
      while (queue.length && !stopped) {
        const unit = queue.shift()!;
        await clock.sleep(first ? timings.firstAudioMs : timings.gapMs);
        first = false;
        if (stopped) {
          break;
        }
        if (this.failSpeak.has(options.voice.engine)) {
          stopped = true;
          callbacks.onError(voiceError('failed', 'synthesis failed'));
          break;
        }
        const entry = {
          id: unit.id,
          text: unit.text,
          voice: options.voice.id,
          rate: options.rate,
          startedAt: clock.now(),
          endedAt: undefined as number | undefined,
        };
        this.log.push(entry);
        this.playing = true;
        callbacks.onUnitStart(unit.id);
        let left = (unit.text.length * timings.msPerChar) / options.rate;
        while (left > 0 && !stopped) {
          if (paused) {
            this.playing = false;
            await new Promise<void>(resolve => resumeWaiters.push(resolve));
            this.playing = !stopped;
            continue;
          }
          const slice = Math.min(20, left);
          await clock.sleep(slice);
          left -= slice;
        }
        this.playing = false;
        if (stopped) {
          break;
        }
        entry.endedAt = clock.now();
        callbacks.onUnitEnd(unit.id);
      }
      running = false;
      if ((ended && queue.length === 0) || stopped) {
        waiter.resolve?.();
      }
    };

    return {
      enqueue: (id, text) => {
        if (!stopped && !ended) {
          queue.push({id, text});
          pump();
        }
      },
      end: () =>
        new Promise<void>(resolve => {
          ended = true;
          if (stopped || (!running && queue.length === 0)) {
            resolve();
          } else {
            waiter.resolve = resolve;
          }
        }),
      stop: async () => {
        if (stopped) {
          return;
        }
        stopped = true;
        queue.length = 0;
        resumeWaiters.forEach(resume => resume());
        resumeWaiters = [];
        await clock.sleep(timings.stopMs);
        this.playing = false;
        waiter.resolve?.();
      },
      pause: async () => {
        paused = true;
      },
      resume: async () => {
        paused = false;
        resumeWaiters.forEach(resume => resume());
        resumeWaiters = [];
      },
    };
  }
}

export interface FakeChatTimings {
  /** Prompt processing before the first word. */
  firstTokenMs: number;
  msPerWord: number;
}

/** A chat model on the virtual clock, with the thread it writes to. */
export class FakeChat implements VoiceChatPort {
  readonly thread: {
    role: 'user' | 'assistant';
    text: string;
    status?: string;
  }[] = [];
  speculations = 0;
  adopted = 0;
  cancelled = 0;
  sends: {text: string; options: VoiceSendOptions}[] = [];
  /** Set to make the next reply fail or never start. */
  failNext: 'error' | 'hang' | null = null;
  private stopCurrent: (() => void) | null = null;
  private chats = 0;

  constructor(
    private readonly clock: VirtualClock,
    public reply: (userText: string) => string = text => `You said: ${text}`,
    public timings: FakeChatTimings = {firstTokenMs: 350, msPerWord: 45},
  ) {}

  private generate(text: string): {
    onWord: (listener: (delta: string) => void) => void;
    done: Promise<'complete' | 'stopped'>;
    stop: () => void;
  } {
    const words = this.reply(text).split(/(?<=\s)/);
    const produced: string[] = [];
    const sink: {listener: ((delta: string) => void) | null} = {listener: null};
    let stopped = false;
    const done = (async () => {
      await this.clock.sleep(this.timings.firstTokenMs);
      for (const word of words) {
        if (stopped) {
          return 'stopped' as const;
        }
        produced.push(word);
        sink.listener?.(word);
        await this.clock.sleep(this.timings.msPerWord);
      }
      return stopped ? ('stopped' as const) : ('complete' as const);
    })();
    return {
      onWord: next => {
        produced.forEach(next);
        sink.listener = next;
      },
      done,
      stop: () => {
        stopped = true;
      },
    };
  }

  private commit(
    text: string,
    options: VoiceSendOptions,
    callbacks: VoiceReplyCallbacks,
    run: ReturnType<FakeChat['generate']>,
  ): Promise<VoiceReplyResult> {
    const conversationId = options.conversationId ?? `chat-${++this.chats}`;
    this.thread.push({role: 'user', text});
    const answer = {role: 'assistant' as const, text: '', status: 'streaming'};
    this.thread.push(answer);
    callbacks.onMessages?.({
      conversationId,
      userMessageId: `u${this.thread.length - 1}`,
      assistantMessageId: `a${this.thread.length}`,
    });
    this.stopCurrent = run.stop;
    run.onWord(delta => {
      answer.text += delta;
      callbacks.onDelta(delta);
    });
    return run.done.then(status => {
      answer.status = status;
      return {status, conversationId};
    });
  }

  async send(
    text: string,
    options: VoiceSendOptions,
    callbacks: VoiceReplyCallbacks,
  ): Promise<VoiceReplyResult> {
    this.sends.push({text, options});
    const fail = this.failNext;
    this.failNext = null;
    if (fail === 'error') {
      await this.clock.sleep(50);
      return {
        status: 'error',
        conversationId: options.conversationId,
        detail: 'model failed',
      };
    }
    if (fail === 'hang') {
      return new Promise(resolve => {
        this.stopCurrent = () =>
          resolve({status: 'stopped', conversationId: options.conversationId});
      });
    }
    return this.commit(text, options, callbacks, this.generate(text));
  }

  stop(): void {
    this.stopCurrent?.();
    this.stopCurrent = null;
  }

  speculate = (text: string, options: VoiceSendOptions): SpeculativeReply => {
    this.speculations++;
    const run = this.generate(text);
    return {
      text,
      commit: callbacks => {
        this.adopted++;
        return this.commit(text, options, callbacks, run);
      },
      cancel: () => {
        this.cancelled++;
        run.stop();
      },
    };
  };
}

/** `FakeChat` without the optional speculation method. */
export function withoutSpeculation(chat: FakeChat): VoiceChatPort {
  return {
    send: chat.send.bind(chat),
    stop: chat.stop.bind(chat),
  };
}

export interface OracleUtterance {
  text: string;
  language: string;
  /** Voiced samples of the full utterance (see `voicedSamples`). */
  voiced: number;
}

/** Samples in frames louder than `floor`. */
export function voicedSamples(pcm: Int16Array, floor = 0.015): number {
  let voiced = 0;
  for (const frame of chunked(pcm, 20)) {
    if (rms(frame) >= floor) {
      voiced += frame.length;
    }
  }
  return voiced;
}

/**
 * A recogniser that "hears" a known utterance: given part of its audio it
 * returns that share of its words, after a decode time that grows with the
 * audio. Silence yields Whisper's favourite phantom.
 */
export class OracleWhisper implements WhisperBackend {
  current: OracleUtterance | null = null;
  decodes = 0;
  /** Decode time: fixed part plus a share of the audio length. */
  decodeMs = (audioMs: number): number => 120 + audioMs * 0.08;
  cancels = 0;
  fail = false;

  constructor(private readonly clock: VirtualClock) {}

  async transcribe(pcm: Int16Array): Promise<{text: string; language: string}> {
    this.decodes++;
    // What is being said when the decode starts is what it hears.
    const utterance = this.current;
    await this.clock.sleep(this.decodeMs(durationMs(pcm.length)));
    if (this.fail) {
      throw new Error('decode failed');
    }
    const voiced = voicedSamples(pcm);
    if (!utterance || voiced < 1600) {
      return {text: ' Thank you.', language: 'en'};
    }
    const words = utterance.text.split(/\s+/);
    const share = Math.min(1, voiced / utterance.voiced);
    const count =
      share > 0.93 ? words.length : Math.floor(words.length * share);
    return {
      text: ' ' + words.slice(0, count).join(' '),
      language: utterance.language,
    };
  }

  async cancel(): Promise<void> {
    this.cancels++;
  }
}

/** A streaming system recogniser: cumulative partials as audio arrives. */
export class FakeSystemRecognizer implements SystemRecognizerBackend {
  current: OracleUtterance | null = null;
  tasks = 0;
  locales = ['en-US', 'en-GB', 'de-DE', 'es-ES', 'fr-FR'];
  maxTaskMs: number | undefined = undefined;
  started: {locale: string; punctuation: boolean}[] = [];

  async supportedLocales(): Promise<string[]> {
    return this.locales;
  }

  async support(locale: string): Promise<SystemRecognizerSupport | null> {
    return this.locales.includes(locale)
      ? {onDevice: true, locale, maxTaskMs: this.maxTaskMs, punctuation: true}
      : null;
  }

  start(
    options: {locale: string; punctuation: boolean},
    onEvent: (event: SystemRecognizerEvent) => void,
  ): SystemRecognizerTask {
    this.tasks++;
    this.started.push(options);
    let voiced = 0;
    let done = false;
    const textNow = () => {
      const utterance = this.current;
      if (!utterance) {
        return '';
      }
      const words = utterance.text.split(/\s+/);
      const share = Math.min(1, voiced / utterance.voiced);
      return words
        .slice(
          0,
          share > 0.93 ? words.length : Math.floor(words.length * share),
        )
        .join(' ');
    };
    return {
      feed: pcm => {
        if (done) {
          return;
        }
        const before = textNow();
        voiced += voicedSamples(pcm);
        const after = textNow();
        if (after !== before) {
          onEvent({type: 'partial', text: after});
        }
      },
      end: async () => {
        if (!done) {
          done = true;
          const text = textNow();
          if (text) {
            onEvent({type: 'final', text});
          }
        }
      },
      abort: () => {
        done = true;
      },
    };
  }
}
