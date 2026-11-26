import {chunked, concatPcm, silence} from '../audio/pcm';
import {
  FakeSystemRecognizer,
  OracleWhisper,
  VirtualClock,
  voicedSamples,
} from '../harness/fakes';
import {fixture, fixturePcm} from '../harness/fixtures';
import {wordErrors, corpusWer} from '../harness/wer';
import {
  planPieces,
  transcribeAudioFile,
  transcribePcm,
} from '../stt/fileTranscriber';
import {listeningLocale, matchLocale, whisperLanguage} from '../stt/language';
import {selectStt, whisperTierFor, type SttFacts} from '../stt/select';
import {SystemSttAdapter} from '../stt/systemAdapter';
import {
  isPhantom,
  joinSegments,
  sameWords,
  stablePrefix,
  tidySegment,
} from '../stt/text';
import type {SttEvent, SttSession} from '../stt/types';
import {WhisperSttAdapter} from '../stt/whisperAdapter';

const oracle = (id: string) => ({
  text: fixture(id).text,
  language: fixture(id).lang,
  voiced: voicedSamples(fixturePcm(id)),
});

/** Feeds audio in 50 ms chunks at real-time pace on the virtual clock. */
async function feed(clock: VirtualClock, session: SttSession, pcm: Int16Array) {
  for (const chunk of chunked(pcm, 50)) {
    session.push(chunk);
    await clock.advance(50);
  }
}

describe('text helpers', () => {
  it('tidies and joins segments', () => {
    expect(tidySegment(' [BLANK_AUDIO] hello (music) there ♪ ')).toBe(
      'Hello there',
    );
    expect(tidySegment('¿Hola, qué tal?', false)).toBe('Hola qué tal');
    expect(joinSegments(['One.', ' two ', '', ', three'])).toBe(
      'One. two, three',
    );
  });

  it('knows Whisper phantoms from short real answers', () => {
    expect(isPhantom('Thank you.', 300)).toBe(true);
    expect(isPhantom('Thank you.', 2000)).toBe(false);
    expect(isPhantom('  ', 5000)).toBe(true);
    expect(isPhantom('Yes, please.', 300)).toBe(false);
  });

  it('finds the prefix two partials agree on', () => {
    expect(
      stablePrefix('what is the capitol', 'What is the capital of France'),
    ).toBe('What is the');
    expect(stablePrefix('', 'Hello')).toBe('');
    expect(sameWords('What is it?', 'what is it')).toBe(true);
  });

  it('scores word errors', () => {
    expect(
      wordErrors(
        'set a timer for fifteen minutes',
        'Set a timer for 15 minutes.',
      ).wer,
    ).toBe(0);
    expect(wordErrors('a b c d', 'a x c').errors).toBe(2);
    expect(
      corpusWer([wordErrors('a b', 'a b'), wordErrors('c d', 'c x')]),
    ).toBe(0.25);
  });
});

describe('language handling', () => {
  it('maps tags to Whisper codes', () => {
    expect(whisperLanguage('auto')).toBeUndefined();
    expect(whisperLanguage('pt-BR')).toBe('pt');
    expect(whisperLanguage('zh_Hans_CN')).toBe('zh');
    expect(whisperLanguage('nb-NO')).toBe('no');
  });

  it('matches the closest supported locale', () => {
    const supported = ['en-US', 'en-GB', 'de-DE', 'pt-BR'];
    expect(matchLocale('en-GB', supported)).toBe('en-GB');
    expect(matchLocale('en-AU', supported)).toBe('en-US');
    expect(matchLocale('de', supported)).toBe('de-DE');
    expect(matchLocale('pt-PT', supported)).toBe('pt-BR');
    expect(matchLocale('ja-JP', supported)).toBeUndefined();
  });

  it('auto listens in a detected language, else the phone language', () => {
    const supported = ['en-US', 'de-DE'];
    expect(
      listeningLocale(
        {setting: 'auto', deviceLocales: ['fr-FR', 'de-AT']},
        supported,
      ),
    ).toBe('de-DE');
    expect(
      listeningLocale(
        {setting: 'auto', deviceLocales: ['de-DE'], detected: 'en'},
        supported,
      ),
    ).toBe('en-US');
    expect(
      listeningLocale({setting: 'de-CH', deviceLocales: ['en-US']}, supported),
    ).toBe('de-DE');
    expect(
      listeningLocale({setting: 'ja', deviceLocales: ['en-US']}, supported),
    ).toBeUndefined();
  });
});

describe('selectStt', () => {
  const facts = (over: Partial<SttFacts>): SttFacts => ({
    platform: 'ios',
    osVersion: '26.1',
    deviceClass: 'C',
    systemOnDevice: true,
    whisperInstalled: ['base'],
    systemModule: true,
    ...over,
  });

  it('iOS 26+: the system transcriber when it has the language', () => {
    expect(selectStt(facts({}))).toMatchObject({
      adapter: 'system',
      reason: 'system_streaming',
    });
    expect(selectStt(facts({systemOnDevice: false}))).toMatchObject({
      adapter: 'whisper',
      whisperTier: 'base',
      reason: 'whisper_language',
      needsDownload: false,
    });
  });

  it('older iOS and Android: Whisper, except class A with an on-device system recogniser', () => {
    expect(selectStt(facts({osVersion: '18.5'}))).toMatchObject({
      adapter: 'whisper',
      reason: 'whisper_default',
    });
    expect(
      selectStt(facts({osVersion: '18.5', deviceClass: 'A'})),
    ).toMatchObject({adapter: 'system', reason: 'system_low_memory'});
    expect(
      selectStt(facts({platform: 'android', osVersion: '36'})),
    ).toMatchObject({adapter: 'whisper'});
    expect(
      selectStt(
        facts({
          platform: 'android',
          osVersion: '36',
          deviceClass: 'A',
          systemOnDevice: false,
        }),
      ),
    ).toMatchObject({adapter: 'whisper', whisperTier: 'base'});
  });

  it('without the native module there is only Whisper', () => {
    expect(selectStt(facts({systemModule: false}))).toMatchObject({
      adapter: 'whisper',
      reason: 'whisper_no_system_module',
    });
  });

  it('picks the tier by class and by what is installed', () => {
    expect(whisperTierFor('B')).toBe('base');
    expect(whisperTierFor('E')).toBe('small');
    expect(
      selectStt(
        facts({
          systemModule: false,
          deviceClass: 'D',
          whisperInstalled: ['base', 'small'],
        }),
      ).whisperTier,
    ).toBe('small');
    expect(
      selectStt(
        facts({
          systemModule: false,
          deviceClass: 'D',
          whisperInstalled: ['base'],
        }),
      ).whisperTier,
    ).toBe('base');
    expect(
      selectStt(facts({systemModule: false, whisperInstalled: []})),
    ).toMatchObject({whisperTier: 'base', needsDownload: true});
  });
});

describe('WhisperSttAdapter (live dictation)', () => {
  function setup() {
    const clock = new VirtualClock();
    const backend = new OracleWhisper(clock);
    const adapter = new WhisperSttAdapter(backend);
    const events: SttEvent[] = [];
    return {
      clock,
      backend,
      adapter,
      events,
      on: (e: SttEvent) => events.push(e),
    };
  }

  it('shows words while speaking, then the final text', async () => {
    const {clock, backend, adapter, events, on} = setup();
    backend.current = oracle('en-ie-trip');
    const session = adapter.start({language: 'auto', mode: 'dictation'}, on);
    await feed(
      clock,
      session,
      concatPcm([silence(300), fixturePcm('en-ie-trip')]),
    );
    const partials = events.filter(e => e.type === 'partial');
    expect(partials.length).toBeGreaterThanOrEqual(3);
    // Partials grow, and the stable part is a prefix of the next partial.
    const lengths = partials.map(p =>
      p.type === 'partial' ? p.text.split(' ').length : 0,
    );
    expect(lengths).toEqual([...lengths].sort((a, b) => a - b));
    const last = partials[partials.length - 1]!;
    expect(last.type === 'partial' && last.text.startsWith(last.stable)).toBe(
      true,
    );
    expect(session.text.length).toBeGreaterThan(10);
    const pending = session.finish();
    await clock.advance(2000);
    const result = await pending;
    expect(result.text).toBe(fixture('en-ie-trip').text);
    expect(result.language).toBe('en');
  });

  it('commits a segment at each pause and drops its audio (no time limit)', async () => {
    const {clock, backend, adapter, events, on} = setup();
    const session = adapter.start({language: 'en', mode: 'dictation'}, on);
    const ids = ['en-us-capital', 'en-gb-timer', 'en-au-plants'];
    await feed(clock, session, silence(300));
    // Ten minutes and more of dictation: 150 utterances with pauses.
    for (let round = 0; round < 50; round++) {
      for (const id of ids) {
        backend.current = oracle(id);
        await feed(clock, session, concatPcm([fixturePcm(id), silence(900)]));
      }
    }
    expect(clock.now()).toBeGreaterThan(10 * 60_000);
    const pending = session.finish();
    await clock.advance(3000);
    const result = await pending;
    expect(result.segments).toHaveLength(150);
    expect(events.filter(e => e.type === 'final')).toHaveLength(150);
    expect(result.text.startsWith(fixture('en-us-capital').text)).toBe(true);
    expect(result.text.endsWith(fixture('en-au-plants').text)).toBe(true);
  });

  it('cuts speech without pauses at the segment cap, at a quiet point', async () => {
    const clock = new VirtualClock();
    const backend = new OracleWhisper(clock);
    const adapter = new WhisperSttAdapter(backend, {maxSegmentMs: 4000});
    const session = adapter.start(
      {language: 'en', mode: 'dictation'},
      () => {},
    );
    backend.current = {text: 'x', language: 'en', voiced: 1};
    const seen: number[] = [];
    const transcribe = backend.transcribe.bind(backend);
    backend.transcribe = pcm => {
      seen.push(pcm.length);
      return transcribe(pcm);
    };
    const speech = fixturePcm('en-ie-trip');
    await feed(clock, session, concatPcm([speech, speech, speech]));
    const pending = session.finish();
    await clock.advance(3000);
    const result = await pending;
    expect(result.segments.length).toBeGreaterThanOrEqual(3);
    // No decode ever saw more than the cap plus the carried tail and pre-roll.
    expect(Math.max(...seen)).toBeLessThanOrEqual(16 * (4000 + 3000 + 400));
  });

  it('drops phantom text on noise and fixes the language after detection', async () => {
    const {clock, backend, adapter, on} = setup();
    const seen: (string | undefined)[] = [];
    const transcribe = backend.transcribe.bind(backend);
    backend.transcribe = (pcm, options?: {language?: string}) => {
      seen.push(options?.language);
      return transcribe(pcm);
    };
    const session = adapter.start({language: 'auto', mode: 'dictation'}, on);
    await feed(clock, session, fixturePcm('room-noise'));
    backend.current = oracle('de-de-wetter');
    await feed(
      clock,
      session,
      concatPcm([fixturePcm('de-de-wetter'), silence(900)]),
    );
    backend.current = oracle('de-de-wetter-snr10');
    await feed(
      clock,
      session,
      concatPcm([fixturePcm('de-de-wetter-snr10'), silence(900)]),
    );
    const pending = session.finish();
    await clock.advance(3000);
    const result = await pending;
    expect(result.segments).toHaveLength(2);
    expect(result.language).toBe('de');
    expect(seen[0]).toBeUndefined();
    expect(seen[seen.length - 1]).toBe('de');
  });

  it('snapshot gives the text so far and saves the final decode when nothing follows', async () => {
    const {clock, backend, adapter, on} = setup();
    backend.current = oracle('en-us-capital');
    const session = adapter.start({language: 'en', mode: 'conversation'}, on);
    await feed(
      clock,
      session,
      concatPcm([fixturePcm('en-us-capital'), silence(300)]),
    );
    const snapshot = session.snapshot();
    await clock.advance(600);
    expect(await snapshot).toBe(fixture('en-us-capital').text);
    const decodes = backend.decodes;
    await feed(clock, session, silence(400));
    const pending = session.finish();
    await clock.advance(1000);
    expect((await pending).text).toBe(fixture('en-us-capital').text);
    expect(backend.decodes).toBe(decodes);
  });

  it('cancel stops the decoder; errors surface', async () => {
    const {clock, backend, adapter, events, on} = setup();
    backend.current = oracle('en-us-capital');
    const session = adapter.start({language: 'en', mode: 'dictation'}, on);
    await feed(clock, session, fixturePcm('en-us-capital').subarray(0, 16000));
    session.cancel();
    expect(backend.cancels).toBe(1);
    session.push(fixturePcm('en-us-capital'));

    backend.fail = true;
    const failing = adapter.start({language: 'en', mode: 'dictation'}, on);
    await feed(clock, failing, fixturePcm('en-us-capital'));
    const pending = failing.finish();
    pending.catch(() => {});
    await clock.advance(3000);
    await expect(pending).rejects.toThrow('decode failed');
    expect(events.some(e => e.type === 'error')).toBe(true);
  });
});

describe('SystemSttAdapter', () => {
  function setup() {
    const clock = new VirtualClock();
    const backend = new FakeSystemRecognizer();
    const adapter = new SystemSttAdapter(backend, async language =>
      language === 'auto' ? 'en-US' : language,
    );
    const events: SttEvent[] = [];
    return {
      clock,
      backend,
      adapter,
      events,
      on: (e: SttEvent) => events.push(e),
    };
  }

  it('streams partials word by word and settles on finish', async () => {
    const {clock, backend, adapter, events, on} = setup();
    backend.current = oracle('en-gb-timer');
    const session = adapter.start(
      {language: 'auto', mode: 'dictation', punctuate: true},
      on,
    );
    await feed(clock, session, fixturePcm('en-gb-timer'));
    expect(events.filter(e => e.type === 'partial').length).toBeGreaterThan(5);
    expect(await session.snapshot()).toBe(session.text);
    const result = await session.finish();
    expect(result.text).toBe(fixture('en-gb-timer').text);
    expect(result.language).toBe('en-US');
    expect(backend.started[0]).toMatchObject({
      locale: 'en-US',
      punctuation: true,
    });
    expect(adapter.trueStreaming).toBe(true);
  });

  it('rolls a time-limited task over at a pause, so long dictation never stops', async () => {
    const {clock, backend, adapter, on} = setup();
    backend.maxTaskMs = 20_000;
    const session = adapter.start({language: 'en-US', mode: 'dictation'}, on);
    for (let i = 0; i < 12; i++) {
      backend.current = oracle('en-us-capital');
      await feed(
        clock,
        session,
        concatPcm([fixturePcm('en-us-capital'), silence(600)]),
      );
    }
    const result = await session.finish();
    expect(backend.tasks).toBeGreaterThanOrEqual(3);
    expect(clock.now()).toBeGreaterThan(40_000);
    expect(result.segments.length).toBeGreaterThanOrEqual(backend.tasks - 1);
    expect(result.text.length).toBeGreaterThan(100);
  });

  it('fails cleanly for a language without on-device recognition', async () => {
    const {adapter, events, on} = setup();
    const session = adapter.start({language: 'ja-JP', mode: 'dictation'}, on);
    session.push(silence(100));
    await expect(session.finish()).rejects.toThrow('no on-device recognition');
    expect(events[0]).toMatchObject({
      type: 'error',
      error: {code: 'unsupported'},
    });
  });

  it('one-shot transcribe and cancel', async () => {
    const {backend, adapter, on} = setup();
    backend.current = oracle('en-us-capital');
    const result = await adapter.transcribe(fixturePcm('en-us-capital'), {
      language: 'en-US',
    });
    expect(result.text).toBe(fixture('en-us-capital').text);
    const session = adapter.start({language: 'en-US', mode: 'dictation'}, on);
    await Promise.resolve();
    session.cancel();
    session.push(silence(100));
    expect(session.text).toBe('');
  });
});

describe('audio file transcription', () => {
  it('plans cuts at quiet points, never longer than a piece', () => {
    const pcm = fixturePcm('en-us-long');
    const cuts = planPieces(pcm, 10_000);
    const bounds = [0, ...cuts, pcm.length];
    expect(cuts.length).toBeGreaterThanOrEqual(3);
    for (let i = 1; i < bounds.length; i++) {
      expect(bounds[i]! - bounds[i - 1]!).toBeLessThanOrEqual(16 * 10_000);
    }
  });

  it('transcribes piece by piece with progress, and stops at the cap', async () => {
    const clock = new VirtualClock();
    const backend = new OracleWhisper(clock);
    backend.decodeMs = () => 0;
    const pcm = fixturePcm('en-us-long');
    backend.current = {text: 'word', language: 'en', voiced: 1};
    const progress: number[] = [];
    const pending = transcribePcm(pcm, new WhisperSttAdapter(backend), {
      pieceMs: 10_000,
      maxDurationMs: 25_000,
      onProgress: p => progress.push(p),
    });
    await clock.advance(1000);
    const result = await pending;
    expect(result.truncated).toBe(true);
    expect(result.segments.length).toBe(progress.length);
    expect(progress[progress.length - 1]).toBe(1);
    expect(result.language).toBe('en');
    expect(result.durationMs).toBeGreaterThan(30_000);
  });

  it('decodes a file first, and reports an unreadable one', async () => {
    const clock = new VirtualClock();
    const backend = new OracleWhisper(clock);
    backend.decodeMs = () => 0;
    backend.current = oracle('en-us-capital');
    const adapter = new WhisperSttAdapter(backend);
    const pcm = fixturePcm('en-us-capital');
    const decoder = {
      decode: async () => ({
        sampleRate: 16000,
        channels: 1,
        data: [Float32Array.from(pcm, v => v / 32768)],
      }),
    };
    const pending = transcribeAudioFile('file:///a.m4a', decoder, adapter);
    await clock.advance(100);
    expect((await pending).text).toBe(fixture('en-us-capital').text);
    await expect(
      transcribeAudioFile(
        'x',
        {decode: async () => Promise.reject(new Error('bad'))},
        adapter,
      ),
    ).rejects.toMatchObject({error: {code: 'unsupported'}});
    await expect(
      transcribePcm(pcm, adapter, {isCancelled: () => true}),
    ).rejects.toMatchObject({error: {code: 'cancelled'}});
  });
});
