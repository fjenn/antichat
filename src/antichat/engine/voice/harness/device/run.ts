/**
 * The voice device harness: feeds the WAV fixtures through the real native
 * pipeline (whisper.rn, the speech library, llama.rn, react-native-audio-api)
 * on a simulator, emulator or phone, and writes what it measured to
 * `Documents/voice-harness/results.json`.
 *
 * Input, put there by `tools/run-device.sh`:
 *   Documents/voice-harness/config.json   {"steps": [...], "model": "x.gguf"}
 *   Documents/voice-harness/fixtures/     manifest.json + *.wav
 * The Whisper model is installed where PocketPal expects it.
 */
import {Platform} from 'react-native';

import * as RNFS from '@dr.pogodin/react-native-fs';
import Speech from '@pocketpalai/react-native-speech';
import {toByteArray} from 'base64-js';

import {getNeuralEngine} from '../../../../../services/tts';
import {
  chunked,
  concatPcm,
  durationMs,
  mixPcm,
  rms,
  silence,
} from '../../audio/pcm';
import {wavToSpeechPcm} from '../../audio/wav';
import {
  createAudioFileDecoder,
  createAudioSession,
  createMicSource,
} from '../../bindings/audio';
import {createSpeechTtsBackend} from '../../bindings/speechTts';
import {
  createWhisperRnBackend,
  installedWhisperTiers,
} from '../../bindings/whisperRn';
import type {TurnLatency} from '../../latency/tracker';
import {LatencyTracker} from '../../latency/tracker';
import type {VoiceChatPort} from '../../mode/chatPort';
import {VoiceModeController, type VoiceModeEvent} from '../../mode/controller';
import type {AudioSessionPort, MicSource} from '../../session/ports';
import type {SttEvent} from '../../stt/types';
import {WhisperSttAdapter} from '../../stt/whisperAdapter';
import {StreamingSpeaker} from '../../tts/streamingSpeaker';
import {SYSTEM_VOICE, findVoice, type CatalogVoice} from '../../tts/voices';
import {corpusWer, wordErrors, type WerResult} from '../wer';
import {createLlamaChat, createScriptedChat} from './chat';

const DIR = `${RNFS.DocumentDirectoryPath}/voice-harness`;
const REPLY =
  'Paris is the capital of France. About two million people live in the city itself, and more than ten million in the wider region.';

interface Fixture {
  id: string;
  file: string;
  lang: string;
  kind: string;
  noiseSnrDb?: number;
  text: string;
}

interface Config {
  steps: string[];
  /** GGUF file name inside Documents/voice-harness/ for a real chat model. */
  model?: string;
  /** Download and measure the Kitten voice (57 MB) too. */
  kitten?: boolean;
  turns?: number;
}

const sleep = (ms: number) =>
  new Promise<void>(resolve => setTimeout(resolve, ms));
const round = (value: number, digits = 3) => Number(value.toFixed(digits));
const median = (values: number[]) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted.length ? sorted[Math.floor((sorted.length - 1) / 2)]! : NaN;
};

export type Report = (line: string) => void;

class Harness {
  results: Record<string, unknown> = {
    platform: Platform.OS,
    osVersion: String(Platform.Version),
    startedAt: new Date().toISOString(),
    finished: false,
  };
  private fixtures: Fixture[] = [];
  private pcm = new Map<string, Int16Array>();

  constructor(private readonly report: Report) {}

  log(line: string): void {
    console.log(`[voice-harness] ${line}`);
    this.report(line);
  }

  async save(): Promise<void> {
    await RNFS.writeFile(
      `${DIR}/results.json`,
      JSON.stringify(this.results, null, 2),
      'utf8',
    );
  }

  async load(): Promise<Config> {
    const config: Config = JSON.parse(
      await RNFS.readFile(`${DIR}/config.json`, 'utf8'),
    );
    this.fixtures = JSON.parse(
      await RNFS.readFile(`${DIR}/fixtures/manifest.json`, 'utf8'),
    );
    for (const fixture of this.fixtures) {
      const base64 = await RNFS.readFile(
        `${DIR}/fixtures/${fixture.file}`,
        'base64',
      );
      this.pcm.set(fixture.id, wavToSpeechPcm(toByteArray(base64)));
    }
    this.log(`loaded ${this.fixtures.length} fixtures`);
    return config;
  }

  audio(id: string): Int16Array {
    return this.pcm.get(id)!;
  }

  text(id: string): string {
    return this.fixtures.find(f => f.id === id)!.text;
  }

  // ------------------------------------------------------------- whisper

  /** Live dictation through whisper.rn, fed in real time. */
  async whisper(): Promise<void> {
    const tiers = await installedWhisperTiers();
    if (!tiers.includes('base')) {
      this.results.whisper = {error: 'ggml-base-q8_0.bin is not installed'};
      return;
    }
    const backend = createWhisperRnBackend(() => 'base');
    const loadStarted = Date.now();
    await backend.preload!();
    const loadMs = Date.now() - loadStarted;
    let decodeMs = 0;
    let decodedAudioMs = 0;
    const timed = {
      ...backend,
      transcribe: async (
        pcm: Int16Array,
        options: {language?: string; prompt?: string},
      ) => {
        const started = Date.now();
        const result = await backend.transcribe(pcm, options);
        decodeMs += Date.now() - started;
        decodedAudioMs += durationMs(pcm.length);
        return result;
      },
    };
    const rows: Record<string, unknown>[] = [];
    const scores: Record<string, WerResult[]> = {
      clean: [],
      noisy: [],
      en: [],
      other: [],
    };
    for (const fixture of this.fixtures.filter(f => f.kind === 'utterance')) {
      const adapter = new WhisperSttAdapter(timed);
      const events: (SttEvent & {at: number})[] = [];
      const started = Date.now();
      const session = adapter.start(
        {language: 'auto', mode: 'dictation'},
        event => events.push({...event, at: Date.now() - started}),
      );
      const speech = this.audio(fixture.id);
      for (const chunk of chunked(
        concatPcm([silence(300), speech, silence(400)]),
        50,
      )) {
        session.push(chunk);
        await sleep(50);
      }
      const speechEnd = Date.now();
      const result = await session.finish();
      const finalMs = Date.now() - speechEnd;
      const score = wordErrors(fixture.text, result.text);
      scores[fixture.noiseSnrDb ? 'noisy' : 'clean']!.push(score);
      scores[fixture.lang === 'en' ? 'en' : 'other']!.push(score);
      const partials = events.filter(e => e.type === 'partial');
      rows.push({
        id: fixture.id,
        lang: fixture.lang,
        detected: result.language,
        wer: round(score.wer),
        partials: partials.length,
        firstPartialMs: partials[0]?.at ?? null,
        finalAfterStopMs: finalMs,
        heard: result.text,
      });
      this.log(
        `whisper ${fixture.id}: wer ${round(score.wer)} partials ${partials.length} "${result.text}"`,
      );
    }
    // Long dictation, faster than real time: segments must still come out whole.
    const long = this.fixtures.find(f => f.kind === 'long');
    let longRow: Record<string, unknown> | null = null;
    if (long) {
      const adapter = new WhisperSttAdapter(timed);
      const session = adapter.start(
        {language: 'en', mode: 'dictation'},
        () => {},
      );
      for (const chunk of chunked(
        concatPcm([this.audio(long.id), silence(900)]),
        50,
      )) {
        session.push(chunk);
        await sleep(10);
      }
      const result = await session.finish();
      longRow = {
        seconds: Math.round(durationMs(this.audio(long.id).length) / 1000),
        segments: result.segments.length,
        wer: round(wordErrors(long.text, result.text).wer),
      };
      this.log(`whisper long: ${JSON.stringify(longRow)}`);
    }
    await backend.release!();
    const all = [...scores.clean!, ...scores.noisy!];
    this.results.whisper = {
      model: 'ggml-base-q8_0.bin',
      loadMs,
      realTimeFactor: round(decodeMs / decodedAudioMs),
      wer: {
        all: round(corpusWer(all)),
        clean: round(corpusWer(scores.clean!)),
        noisy: round(corpusWer(scores.noisy!)),
        english: round(corpusWer(scores.en!)),
        otherLanguages: round(corpusWer(scores.other!)),
      },
      medianFirstPartialMs: median(
        rows.map(r => r.firstPartialMs as number).filter(Boolean),
      ),
      medianFinalAfterStopMs: median(
        rows.map(r => r.finalAfterStopMs as number),
      ),
      long: longRow,
      rows,
    };
  }

  // ----------------------------------------------------------------- tts

  private async ttsVoice(
    voice: CatalogVoice,
    runs: number,
  ): Promise<Record<string, unknown>> {
    const backend = createSpeechTtsBackend();
    const prepareStarted = Date.now();
    await backend.prepare(voice);
    const prepareMs = Date.now() - prepareStarted;
    const firstAudio: number[] = [];
    const stops: number[] = [];
    let stillSpeaking = 0;
    const errors: string[] = [];
    for (let i = 0; i < runs; i++) {
      const speaker = new StreamingSpeaker(backend, {voice, language: 'en-US'});
      let unitAt = 0;
      let audioAt = 0;
      speaker.events.on(event => {
        if (event.type === 'first_unit') {
          unitAt = event.atMs;
        } else if (event.type === 'unit_start' && event.first) {
          audioAt = event.atMs;
        } else if (event.type === 'error') {
          errors.push(event.error.detail ?? 'error');
        }
      });
      // The answer arrives like a model writes it: 25 tokens a second.
      (async () => {
        for (const word of `${REPLY} ${REPLY}`.split(/(?<=\s)/)) {
          speaker.push(word);
          await sleep(40);
        }
        speaker.finish().catch(() => {});
      })();
      const deadline = Date.now() + 15_000;
      while (!audioAt && Date.now() < deadline && errors.length === 0) {
        await sleep(10);
      }
      if (!audioAt) {
        errors.push('no audio within 15 s');
        await speaker.stop();
        break;
      }
      firstAudio.push(audioAt - unitAt);
      // Barge-in on the real speaker: how long until it is silent?
      await sleep(1200);
      const stopStarted = Date.now();
      await speaker.stop();
      stops.push(Date.now() - stopStarted);
      if (await Speech.isSpeaking().catch(() => false)) {
        stillSpeaking++;
      }
      await sleep(400);
    }
    await backend.release();
    return {
      voice: voice.id,
      prepareMs,
      runs: firstAudio.length,
      firstAudioMs: firstAudio,
      medianFirstAudioMs: median(firstAudio),
      stopMs: stops,
      maxStopMs: stops.length ? Math.max(...stops) : null,
      stillSpeakingAfterStop: stillSpeaking,
      errors,
    };
  }

  async tts(config: Config): Promise<void> {
    const voices: Record<string, unknown>[] = [];
    voices.push(
      await this.ttsVoice(SYSTEM_VOICE, 5).catch(err => ({
        voice: 'system',
        error: String(err),
      })),
    );
    this.log(`tts system: ${JSON.stringify(voices[0])}`);
    if (config.kitten) {
      try {
        const engine = getNeuralEngine('kitten');
        if (!(await engine.isInstalled())) {
          this.log('tts: downloading Kitten (57 MB)');
          await engine.downloadModel();
        }
        voices.push(
          await this.ttsVoice(findVoice('kitten:expr-voice-2-f')!, 5),
        );
      } catch (err) {
        voices.push({voice: 'kitten', error: String(err)});
      }
      this.log(`tts kitten: ${JSON.stringify(voices[1])}`);
    }
    this.results.tts = {voices};
  }

  // ---------------------------------------------------------- voice mode

  /** The whole loop on the real recogniser and voice, microphone fed from fixtures. */
  private async voiceRun(
    chat: VoiceChatPort,
    voice: CatalogVoice,
    options: {speculativeMs: number; turns: string[]; bargeIn: boolean},
  ) {
    const input: {onChunk: ((pcm: Int16Array) => void) | null} = {
      onChunk: null,
    };
    const mic: MicSource = {
      start: async listener => {
        input.onChunk = listener;
      },
      stop: async () => {
        input.onChunk = null;
      },
    };
    const session: AudioSessionPort = {
      activate: async () => ({route: 'speaker', echoCancellation: true}),
      deactivate: async () => {},
      setOutput: async () => ({route: 'speaker', echoCancellation: true}),
      on: () => () => {},
    };
    const controller = new VoiceModeController(
      {
        session,
        mic,
        stt: new WhisperSttAdapter(createWhisperRnBackend(() => 'base')),
        tts: createSpeechTtsBackend(),
        chat,
      },
      {
        language: 'en',
        voice,
        speculativeMs: options.speculativeMs,
        idleTimeoutMs: 600_000,
      },
    );
    const events: VoiceModeEvent[] = [];
    controller.events.on(event => {
      if (event.type !== 'level') {
        events.push(event);
      }
    });
    // The microphone: 50 ms chunks in real time; while the answer plays, what
    // an echo canceller leaves of it (the reply fixture at -22 dB).
    const echo = this.audio('en-us-reply');
    let echoAt = 0;
    let queue: Int16Array[] = [];
    let running = true;
    const pump = (async () => {
      let next = Date.now();
      while (running) {
        let chunk = queue.shift() ?? silence(50);
        if (controller.phase === 'speaking') {
          if (echoAt + 800 > echo.length) {
            echoAt = 0;
          }
          chunk = mixPcm(chunk, echo.subarray(echoAt, echoAt + 800), 0.08);
          echoAt += 800;
        }
        input.onChunk?.(chunk);
        next += 50;
        await sleep(Math.max(0, next - Date.now()));
      }
    })();
    const say = (id: string) => {
      const padded = concatPcm([this.audio(id), silence(40)]);
      queue = [...chunked(padded, 50)].map(chunk => {
        const full = new Int16Array(800);
        full.set(chunk);
        return full;
      });
    };
    const until = async (test: () => boolean, limitMs: number) => {
      const deadline = Date.now() + limitMs;
      while (!test() && Date.now() < deadline) {
        await sleep(25);
      }
      return test();
    };

    await controller.start(null);
    await sleep(500);
    const bargeIns: {detectMs: number; stopMs: number}[] = [];
    for (const id of options.turns) {
      const before = events.filter(e => e.type === 'assistant_done').length;
      say(id);
      await until(() => queue.length === 0, 30_000);
      if (options.bargeIn) {
        if (await until(() => controller.phase === 'speaking', 60_000)) {
          await sleep(1300);
          const voiced = () =>
            events.filter(e => e.type === 'barge_in' && e.by === 'voice');
          const seen = voiced().length;
          say('en-us-bargein');
          await until(() => voiced().length > seen, 8000);
          const barge = voiced()[seen];
          if (barge && barge.type === 'barge_in') {
            bargeIns.push(barge);
          }
          // Let the interrupting turn be answered, then cut that short too.
          await until(() => controller.phase === 'speaking', 60_000);
          controller.interrupt();
          await sleep(1500);
        }
      } else {
        await until(
          () => events.filter(e => e.type === 'assistant_done').length > before,
          90_000,
        );
        await sleep(800);
      }
    }
    running = false;
    await pump;
    await controller.stop();
    const turns = events.flatMap(e => (e.type === 'latency' ? [e.turn] : []));
    return {
      turns,
      bargeIns,
      userTurns: events.flatMap(e => (e.type === 'user_turn' ? [e.text] : [])),
      errors: events.flatMap(e =>
        e.type === 'error' ? [`${e.stage}: ${e.error.detail}`] : [],
      ),
    };
  }

  async voice(config: Config): Promise<void> {
    const ids = [
      'en-us-capital',
      'en-gb-timer',
      'en-au-plants',
      'en-in-recipe',
      'en-ie-trip',
    ].slice(0, config.turns ?? 5);
    const summarise = (turns: TurnLatency[]) =>
      new LatencyTracker().summary(turns);
    let llama: Awaited<ReturnType<typeof createLlamaChat>> | null = null;
    let chatKind = 'scripted (400 ms to first token, 20 tokens/s)';
    if (config.model) {
      try {
        llama = await createLlamaChat(`${DIR}/${config.model}`);
        chatKind = `${config.model} on llama.rn (loaded in ${llama.loadMs} ms)`;
      } catch (err) {
        this.log(`llama failed to load, using the scripted chat: ${err}`);
      }
    }
    const chat = () => llama ?? createScriptedChat(REPLY);
    const out: Record<string, unknown> = {
      chat: chatKind,
      voice: SYSTEM_VOICE.id,
    };
    this.results.voice = out;
    for (const [name, speculativeMs] of [
      ['speculationOff', 0],
      ['speculationOn', 300],
    ] as const) {
      const run = await this.voiceRun(chat(), SYSTEM_VOICE, {
        speculativeMs,
        turns: ids,
        bargeIn: false,
      });
      out[name] = {
        summary: summarise(run.turns),
        adopted: run.turns.filter(t => t.speculation === 'adopted').length,
        turns: run.turns.map(t => ({
          endpointingMs: t.endpointingMs,
          sttMs: t.sttMs,
          llmFirstSentenceMs: t.llmFirstSentenceMs,
          ttsFirstAudioMs: t.ttsFirstAudioMs,
          totalMs: t.totalMs,
          speculation: t.speculation,
        })),
        wer: round(
          corpusWer(
            ids.map((id, i) =>
              wordErrors(this.text(id), run.userTurns[i] ?? ''),
            ),
          ),
        ),
        userTurns: run.userTurns.length,
        // More user turns than were said would be the answer leaking back in.
        leakedTurns: Math.max(0, run.userTurns.length - ids.length),
        errors: run.errors,
      };
      this.log(
        `voice ${name}: ${JSON.stringify((out[name] as {summary: unknown}).summary)}`,
      );
      await this.save();
    }
    // A long scripted answer, so there is speech to interrupt.
    const barge = await this.voiceRun(
      createScriptedChat(`${REPLY} ${REPLY} ${REPLY}`),
      SYSTEM_VOICE,
      {
        speculativeMs: 0,
        turns: ids.slice(0, 3),
        bargeIn: true,
      },
    );
    out.bargeIn = {
      attempts: 3,
      runs: barge.bargeIns.length,
      detectMs: barge.bargeIns.map(b => b.detectMs),
      stopMs: barge.bargeIns.map(b => b.stopMs),
      onsetToSilentMs: barge.bargeIns.map(b => b.detectMs + b.stopMs),
      heardAfter: barge.userTurns.filter(t => /italy/i.test(t)).length,
      errors: barge.errors,
    };
    this.log(`voice barge-in: ${JSON.stringify(out.bargeIn)}`);
    await llama?.release();
    this.results.voice = out;
  }

  /** One spoken interruption and one by the button: the barge-in smoke check. */
  async bargeIn(): Promise<void> {
    const barge = await this.voiceRun(
      createScriptedChat(`${REPLY} ${REPLY} ${REPLY}`),
      SYSTEM_VOICE,
      {speculativeMs: 0, turns: ['en-us-capital'], bargeIn: true},
    );
    this.results.bargeIn = {
      attempts: 1,
      runs: barge.bargeIns.length,
      detectMs: barge.bargeIns.map(b => b.detectMs),
      stopMs: barge.bargeIns.map(b => b.stopMs),
      heardAfter: barge.userTurns.filter(t => /italy/i.test(t)).length,
      userTurns: barge.userTurns,
      errors: barge.errors,
    };
    this.log(`barge-in: ${JSON.stringify(this.results.bargeIn)}`);
  }

  // ------------------------------------------------------------- session

  /** The real audio session, recorder and decoder: do the bindings work here? */
  async session(): Promise<void> {
    const out: Record<string, unknown> = {};
    try {
      const decoder = createAudioFileDecoder();
      const decoded = await decoder.decode(`${DIR}/fixtures/en-us-capital.wav`);
      out.decoder = {
        sampleRate: decoded.sampleRate,
        channels: decoded.channels,
        samples: decoded.data[0]?.length ?? 0,
        expected: this.audio('en-us-capital').length,
      };
    } catch (err) {
      out.decoder = {error: String(err)};
    }
    const session = createAudioSession();
    const mic = createMicSource();
    try {
      const info = await session.activate('conversation');
      const sizes: number[] = [];
      let peak = 0;
      const started = Date.now();
      let firstChunkMs: number | null = null;
      await mic.start(
        pcm => {
          firstChunkMs ??= Date.now() - started;
          sizes.push(pcm.length);
          peak = Math.max(peak, rms(pcm));
        },
        {echoCancellation: info.echoCancellation},
      );
      await sleep(2000);
      await mic.stop();
      out.mic = {
        route: info.route,
        echoCancellation: info.echoCancellation,
        chunks: sizes.length,
        samplesPerChunk: median(sizes),
        capturedMs: Math.round(durationMs(sizes.reduce((a, b) => a + b, 0))),
        firstChunkMs,
      };
    } catch (err) {
      out.mic = {error: String(err)};
    }
    await session.deactivate().catch(() => {});
    this.log(`session: ${JSON.stringify(out)}`);
    this.results.session = out;
  }
}

export async function runHarness(report: Report): Promise<void> {
  const harness = new Harness(report);
  try {
    const config = await harness.load();
    harness.results.config = config;
    for (const step of config.steps) {
      harness.log(`step ${step}`);
      try {
        if (step === 'whisper') {
          await harness.whisper();
        } else if (step === 'tts') {
          await harness.tts(config);
        } else if (step === 'voice') {
          await harness.voice(config);
        } else if (step === 'bargein') {
          await harness.bargeIn();
        } else if (step === 'session') {
          await harness.session();
        }
      } catch (err) {
        harness.results[step] = {
          ...(harness.results[step] as object | undefined),
          error: String(err instanceof Error ? err.stack : err),
        };
        harness.log(`step ${step} failed: ${err}`);
      }
      await harness.save();
    }
  } catch (err) {
    harness.results.error = String(err instanceof Error ? err.stack : err);
    harness.log(`failed: ${err}`);
  }
  harness.results.finished = true;
  harness.results.finishedAt = new Date().toISOString();
  await harness.save().catch(() => {});
  harness.log('finished');
}
