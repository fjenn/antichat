/**
 * The recogniser pipeline on real speech, scored against the fixtures'
 * reference texts. Runs only with `VOICE_HOST=1` and whisper.cpp installed
 * (`brew install whisper-cpp`, model in models/voice/), because it spawns the
 * decoder; the default Jest run skips it.
 *
 *   VOICE_HOST=1 yarn jest src/antichat/engine/voice/__tests__/hostAudio --coverage=false
 *
 * Writes harness/results/host-whisper.json.
 */
import fs from 'fs';
import path from 'path';

import {chunked, concatPcm, mixPcm, silence} from '../audio/pcm';
import {fixture, fixturePcm, fixtures} from '../harness/fixtures';
import {
  hostWhisperAvailable,
  WhisperCliBackend,
} from '../harness/host/whisperCli';
import {VoiceRig} from '../harness/rig';
import {corpusWer, wordErrors, type WerResult} from '../harness/wer';
import {transcribePcm} from '../stt/fileTranscriber';
import type {SttEvent} from '../stt/types';
import {WhisperSttAdapter} from '../stt/whisperAdapter';

const enabled = process.env.VOICE_HOST === '1' && hostWhisperAvailable();
const suite = enabled ? describe : describe.skip;
const RESULTS = path.join(__dirname, '../harness/results/host-whisper.json');
const report: Record<string, unknown> = {};

suite('host: whisper.cpp base q8 through the live dictation path', () => {
  jest.setTimeout(600_000);
  const backend = enabled ? new WhisperCliBackend() : (null as never);

  afterAll(() => {
    backend.dispose();
    fs.mkdirSync(path.dirname(RESULTS), {recursive: true});
    fs.writeFileSync(RESULTS, JSON.stringify(report, null, 2) + '\n');
  });

  it('word error rate per fixture, with live partials', async () => {
    const rows: Record<string, unknown>[] = [];
    const scores: Record<string, WerResult[]> = {
      clean: [],
      noisy: [],
      en: [],
      other: [],
    };
    for (const f of fixtures().filter(x => x.kind === 'utterance')) {
      const adapter = new WhisperSttAdapter(backend);
      const events: SttEvent[] = [];
      const session = adapter.start({language: 'auto', mode: 'dictation'}, e =>
        events.push(e),
      );
      for (const chunk of chunked(
        concatPcm([silence(300), fixturePcm(f.id), silence(900)]),
        50,
      )) {
        session.push(chunk);
        await Promise.resolve();
      }
      const result = await session.finish();
      const score = wordErrors(f.text, result.text);
      scores[f.noiseSnrDb ? 'noisy' : 'clean']!.push(score);
      scores[f.lang === 'en' ? 'en' : 'other']!.push(score);
      rows.push({
        id: f.id,
        lang: f.lang,
        detected: result.language,
        snrDb: f.noiseSnrDb ?? null,
        wer: Number(score.wer.toFixed(3)),
        partials: events.filter(e => e.type === 'partial').length,
        heard: result.text,
      });
      expect(result.language).toBe(f.lang);
    }
    const all = Object.values({a: scores.clean!, b: scores.noisy!}).flat();
    report.dictation = {
      rows,
      wer: {
        all: Number(corpusWer(all).toFixed(3)),
        clean: Number(corpusWer(scores.clean!).toFixed(3)),
        noisy: Number(corpusWer(scores.noisy!).toFixed(3)),
        english: Number(corpusWer(scores.en!).toFixed(3)),
        otherLanguages: Number(corpusWer(scores.other!).toFixed(3)),
      },
      realTimeFactor: Number(
        (backend.decodeWallMs / backend.audioMs).toFixed(3),
      ),
    };
    console.log(JSON.stringify(report.dictation, null, 1));
    expect(corpusWer(scores.clean!)).toBeLessThan(0.1);
    expect(corpusWer(all)).toBeLessThan(0.15);
    expect(rows.every(r => (r.partials as number) >= 1)).toBe(true);
  });

  it('long dictation: nothing is lost across segments', async () => {
    const adapter = new WhisperSttAdapter(backend);
    const session = adapter.start(
      {language: 'en', mode: 'dictation'},
      () => {},
    );
    for (const chunk of chunked(
      concatPcm([fixturePcm('en-us-long'), silence(900)]),
      50,
    )) {
      session.push(chunk);
      await Promise.resolve();
    }
    const result = await session.finish();
    const score = wordErrors(fixture('en-us-long').text, result.text);
    report.longDictation = {
      seconds: Math.round(fixturePcm('en-us-long').length / 16000),
      segments: result.segments.length,
      wer: Number(score.wer.toFixed(3)),
    };
    console.log(JSON.stringify(report.longDictation));
    expect(result.segments.length).toBeGreaterThanOrEqual(4);
    expect(score.wer).toBeLessThan(0.1);
  });

  it('audio attachment: the same recording as a file', async () => {
    const result = await transcribePcm(
      fixturePcm('en-us-long'),
      new WhisperSttAdapter(backend),
      {
        pieceMs: 15_000,
      },
    );
    const score = wordErrors(fixture('en-us-long').text, result.text);
    report.fileTranscription = {
      pieces: result.segments.length,
      wer: Number(score.wer.toFixed(3)),
    };
    console.log(JSON.stringify(report.fileTranscription));
    expect(score.wer).toBeLessThan(0.1);
    expect(result.language).toBe('en');
  });

  it('TTS does not leak into STT: echo of the answer never becomes a user turn', async () => {
    // What reaches the microphone is perfectly recognisable on its own…
    const echo = mixPcm(silence(1), fixturePcm('en-us-reply'), 0.08);
    const raw = await backend.transcribe(echo, {language: 'en'});
    const rawWer = wordErrors(fixture('en-us-reply').text, raw.text).wer;
    // …so the guard has to keep it away from the recogniser.
    const rig = new VoiceRig({
      echoGain: 0.08,
      stt: () => new WhisperSttAdapter(backend),
      reply: () => fixture('en-us-reply').text,
      config: {speculativeMs: 0},
    });
    await rig.start();
    const said = [
      'en-us-capital',
      'en-gb-timer',
      'en-au-plants',
      'en-in-recipe',
      'en-ie-trip',
    ];
    for (const id of said) {
      await rig.turn(id);
      await rig.quiet(1500);
    }
    const turns = rig.of('user_turn').map(e => e.text);
    const leaked = turns.length - said.length;
    report.echo = {
      echoGain: 0.08,
      rawEchoWer: Number(rawWer.toFixed(3)),
      turnsSaid: said.length,
      userTurnsCommitted: turns.length,
      leakedTurns: leaked,
      falseBargeIns: rig.of('barge_in').length,
      werOfTurns: Number(
        corpusWer(
          said.map((id, i) => wordErrors(fixture(id).text, turns[i] ?? '')),
        ).toFixed(3),
      ),
    };
    console.log(JSON.stringify(report.echo));
    expect(rawWer).toBeLessThan(0.2);
    expect(leaked).toBe(0);
    expect(rig.of('barge_in')).toHaveLength(0);
    expect(rig.chat.thread).toHaveLength(10);
  });

  it('barge-in over the echo: stop time and the words that interrupted', async () => {
    const stops: number[] = [];
    let heard = '';
    for (let i = 0; i < 5; i++) {
      const rig = new VoiceRig({
        echoGain: 0.08,
        stt: () => new WhisperSttAdapter(backend),
        chat: {msPerWord: 200},
        reply: () => fixture('en-us-reply').text,
        config: {speculativeMs: 0},
      });
      await rig.start();
      await rig.say('en-us-capital');
      await rig.until('speaking');
      await rig.quiet(900 + i * 350);
      await rig.say('en-us-bargein');
      const barge = rig.of('barge_in')[0]!;
      stops.push(barge.detectMs + barge.stopMs);
      await rig.until('thinking');
      await rig.quiet(200);
      heard = rig.of('user_turn')[1]?.text ?? '';
      expect(
        wordErrors(fixture('en-us-bargein').text, heard).wer,
      ).toBeLessThanOrEqual(0.3);
    }
    report.bargeIn = {
      note: 'onset of the interrupting speech to speaker silent; the speaker stop itself is simulated (40 ms)',
      onsetToSilentMs: stops,
      heard,
    };
    console.log(JSON.stringify(report.bargeIn));
    expect(Math.max(...stops)).toBeLessThan(500);
  });
});
