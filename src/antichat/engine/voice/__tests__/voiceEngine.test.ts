import {chunked, concatPcm, silence} from '../audio/pcm';
import {
  FakeChat,
  FakeKeepAwake,
  FakeMic,
  FakeSession,
  FakeTts,
  OracleWhisper,
  VirtualClock,
  voicedSamples,
} from '../harness/fakes';
import {fixture, fixturePcm} from '../harness/fixtures';
import type {VoicePortEvent} from '../port';
import {WhisperSttAdapter} from '../stt/whisperAdapter';
import type {TtsEngineId} from '../tts/voices';
import {VoiceEngine, type VoiceEngineDeps} from '../VoiceEngine';

function setup(over: Partial<VoiceEngineDeps> = {}, permission = 'granted') {
  const clock = new VirtualClock();
  const mic = new FakeMic();
  const session = new FakeSession();
  const whisper = new OracleWhisper(clock);
  const tts = new FakeTts(clock, {
    prepareMs: 0,
    firstAudioMs: 100,
    gapMs: 0,
    msPerChar: 20,
    stopMs: 10,
  });
  const chat = new FakeChat(clock, () => 'Paris is the capital. It is big.');
  const keepAwake = new FakeKeepAwake();
  const installed: TtsEngineId[] = [];
  const persisted: unknown[] = [];
  let sttReleases = 0;
  const stt = new WhisperSttAdapter(whisper);
  const release = stt.release.bind(stt);
  stt.release = async () => {
    sttReleases++;
    await release();
  };
  const engine = new VoiceEngine({
    stt,
    tts,
    session,
    mic,
    chat,
    keepAwake,
    clock,
    permission: {ensure: async () => permission as 'granted'},
    facts: () => ({
      deviceClass: 'C',
      platform: 'ios',
      phononSupported: false,
      installedEngines: installed,
      language: 'en-US',
    }),
    installEngine: async (id, onProgress) => {
      onProgress(0.5);
      onProgress(1);
      installed.push(id);
    },
    decoder: {
      decode: async () => ({
        sampleRate: 16000,
        channels: 1,
        data: [Float32Array.from(fixturePcm('en-us-capital'), v => v / 32768)],
      }),
    },
    onPersist: state => persisted.push(state),
    dictationWarmMs: 5000,
    voiceWarmMs: 5000,
    ...over,
  });
  let changes = 0;
  engine.subscribe(() => changes++);
  const events: VoicePortEvent[] = [];
  engine.onEvent(e => events.push(e));
  const speak = async (id: string, tailMs = 0) => {
    whisper.current = {
      text: fixture(id).text,
      language: 'en',
      voiced: voicedSamples(fixturePcm(id)),
    };
    for (const chunk of chunked(
      concatPcm([fixturePcm(id), silence(tailMs)]),
      50,
    )) {
      mic.emit(chunk);
      await clock.advance(50);
    }
  };
  return {
    clock,
    mic,
    session,
    whisper,
    tts,
    chat,
    keepAwake,
    engine,
    events,
    speak,
    persisted,
    changes: () => changes,
    sttReleases: () => sttReleases,
  };
}

describe('VoiceEngine: dictation', () => {
  it('shows words while speaking and resolves with the final text', async () => {
    const t = setup();
    const starting = t.engine.startDictation();
    expect(t.engine.dictation).toEqual({status: 'starting'});
    await t.clock.advance(10);
    await starting;
    expect(t.engine.dictation).toMatchObject({
      status: 'listening',
      partial: '',
    });
    expect(t.session.profile).toBe('dictation');
    expect(t.keepAwake.holds).toBe(1);
    await t.speak('en-ie-trip');
    const state = t.engine.dictation;
    if (state.status !== 'listening') {
      throw new Error('not listening');
    }
    expect(state.partial.length).toBeGreaterThan(10);
    expect(state.stableLength).toBeLessThanOrEqual(state.partial.length);
    expect(state.stableLength).toBeGreaterThan(0);
    const finishing = t.engine.finishDictation();
    expect(t.engine.dictation).toEqual({status: 'transcribing'});
    await t.clock.advance(2000);
    expect(await finishing).toBe(fixture('en-ie-trip').text);
    expect(t.engine.dictation).toEqual({status: 'idle'});
    expect(t.mic.running).toBe(false);
    expect(t.session.profile).toBeNull();
    expect(t.keepAwake.holds).toBe(0);
    expect(t.changes()).toBeGreaterThan(10);
    // The recogniser is unloaded once the warm time has passed.
    expect(t.sttReleases()).toBe(0);
    await t.clock.advance(5100);
    expect(t.sttReleases()).toBe(1);
  });

  it('cancel discards; a second start while listening is ignored', async () => {
    const t = setup();
    t.engine.startDictation();
    await t.clock.advance(10);
    await t.engine.startDictation();
    expect(t.mic.started).toBe(1);
    await t.speak('en-us-capital');
    t.engine.cancelDictation();
    expect(t.engine.dictation).toEqual({status: 'idle'});
    expect(await t.engine.finishDictation()).toBe('');
    expect(t.whisper.cancels).toBe(1);
  });

  it('fails with a reason when the microphone is refused', async () => {
    const t = setup({}, 'denied');
    t.engine.startDictation();
    await t.clock.advance(10);
    expect(t.engine.dictation).toMatchObject({
      status: 'failed',
      error: {code: 'permission_denied'},
    });
    expect(t.mic.started).toBe(0);
  });
});

describe('VoiceEngine: read aloud', () => {
  const text = 'First sentence. Second sentence. Third sentence.';

  it('exposes sentence, range, progress and speed', async () => {
    const t = setup();
    t.engine.speak('m1', text);
    await t.clock.advance(150);
    expect(t.session.profile).toBe('playback');
    expect(t.engine.speech).toMatchObject({
      status: 'speaking',
      messageId: 'm1',
      sentence: 0,
      sentenceCount: 3,
      range: {start: 0, end: 15},
      rate: 1,
    });
    t.engine.skipSpeech(1);
    await t.clock.advance(150);
    expect(t.engine.speech).toMatchObject({
      sentence: 1,
      range: {start: 16, end: 32},
    });
    t.engine.pauseSpeech();
    expect(t.engine.speech.status).toBe('paused');
    t.engine.seekSpeech(2);
    t.engine.skipSpeech(-1);
    t.engine.setSpeechRate(1.5);
    expect(t.engine.speech).toMatchObject({
      status: 'paused',
      sentence: 1,
      rate: 1.5,
    });
    t.engine.resumeSpeech();
    await t.clock.advance(5000);
    expect(t.engine.speech).toEqual({status: 'idle'});
    expect(t.session.profile).toBeNull();
    expect(t.tts.log[t.tts.log.length - 1]).toMatchObject({
      text: 'Third sentence.',
      rate: 1.5,
    });
    expect(t.persisted[t.persisted.length - 1]).toMatchObject({rate: 1.5});
  });

  it('stop, and pronounce a selection', async () => {
    const t = setup();
    t.engine.speak('m1', text);
    await t.clock.advance(150);
    t.engine.stopSpeech();
    await t.clock.advance(50);
    expect(t.engine.speech).toEqual({status: 'idle'});
    const saying = t.engine.pronounce('GGUF');
    await t.clock.advance(1000);
    await saying;
    expect(t.tts.log[t.tts.log.length - 1]!.text).toBe('G G U F');
    await t.engine.pronounce('🙂');
  });
});

describe('VoiceEngine: voices and settings', () => {
  it('lists voices for the phone, downloads on choice, persists', async () => {
    const t = setup();
    expect(t.engine.voiceId).toBeNull();
    const voices = t.engine.voices;
    expect(voices.map(v => v.id)).toEqual([
      'kokoro:af_heart',
      'kokoro:am_michael',
      'kokoro:bf_emma',
      'kitten:expr-voice-2-f',
      'supertonic:F1',
      'supertonic:M1',
      'system:default',
    ]);
    expect(voices[0]).toMatchObject({
      installed: false,
      recommended: true,
      downloadBytes: 330 * 1024 * 1024,
    });
    expect(voices[voices.length - 1]).toMatchObject({
      installed: true,
      downloadBytes: 0,
    });
    await t.engine.setVoice('kokoro:bf_emma');
    expect(t.events.filter(e => e.type === 'voice_download')).toHaveLength(2);
    expect(t.engine.voiceId).toBe('kokoro:bf_emma');
    expect(
      t.engine.voices.find(v => v.id === 'kokoro:bf_emma')!.installed,
    ).toBe(true);
    t.engine.speak('m1', 'Hello there.');
    await t.clock.advance(200);
    expect(t.tts.log[0]!.voice).toBe('kokoro:bf_emma');
    await expect(t.engine.setVoice('nope:x')).rejects.toThrow('unknown voice');
  });

  it('settings: language, punctuation and pronunciations apply', async () => {
    const t = setup();
    t.engine.updateSettings({
      pronunciations: [{word: 'Paris', say: 'Paree'}],
      punctuation: false,
    });
    expect(t.engine.settings.punctuation).toBe(false);
    t.engine.speak('m1', 'Paris is big.');
    await t.clock.advance(200);
    expect(t.tts.log[0]!.text).toBe('Paree is big.');
    await t.clock.advance(2000);
    t.engine.startDictation();
    await t.clock.advance(10);
    await t.speak('en-us-capital');
    const finishing = t.engine.finishDictation();
    await t.clock.advance(2000);
    expect(await finishing).toBe(
      'What is the capital of France and how many people live there',
    );
  });

  it('transcribes an audio attachment', async () => {
    const t = setup();
    t.whisper.current = {
      text: fixture('en-us-capital').text,
      language: 'en',
      voiced: voicedSamples(fixturePcm('en-us-capital')),
    };
    const progress: number[] = [];
    const pending = t.engine.transcribeFile('file:///memo.m4a', p =>
      progress.push(p),
    );
    await t.clock.advance(2000);
    expect((await pending).text).toBe(fixture('en-us-capital').text);
    expect(progress).toEqual([1]);
    const bare = setup({decoder: undefined});
    await expect(bare.engine.transcribeFile('x')).rejects.toThrow(
      'no audio decoder',
    );
  });
});

describe('VoiceEngine: voice mode', () => {
  it('maps the controller to port state and events, and owns the audio alone', async () => {
    const t = setup();
    t.engine.speak('m0', 'Something long to read aloud here.');
    await t.clock.advance(150);
    const starting = t.engine.startVoiceMode('chat-1');
    await t.clock.advance(100);
    await starting;
    expect(t.engine.speech).toEqual({status: 'idle'}); // read-aloud gave way
    expect(t.engine.voiceMode).toMatchObject({status: 'listening'});
    await t.engine.startDictation(); // refused while voice mode runs
    expect(t.engine.dictation).toEqual({status: 'idle'});
    await t.engine.speak('m9', 'Ignored.');

    await t.speak('en-us-capital', 400);
    const listening = t.engine.voiceMode;
    expect(
      listening.status === 'listening' && listening.partial.length > 0,
    ).toBe(true);
    const quiet = async (ms: number) => {
      for (let at = 0; at < ms; at += 50) {
        t.mic.emit(silence(50));
        await t.clock.advance(50);
      }
    };
    await quiet(350);
    expect(t.engine.voiceMode.status).toBe('thinking');
    for (let i = 0; i < 100 && t.engine.voiceMode.status !== 'speaking'; i++) {
      await quiet(50);
    }
    expect(t.engine.voiceMode).toEqual({status: 'speaking', level: 0});
    t.engine.interrupt();
    expect(t.engine.voiceMode.status).toBe('listening');
    t.engine.setMuted(true);
    expect(t.engine.voiceMode).toEqual({status: 'muted'});
    t.engine.setMuted(false);
    await t.clock.advance(100);
    expect(t.events.map(e => e.type)).toEqual(
      expect.arrayContaining([
        'route',
        'user_turn',
        'latency',
        'barge_in',
        'assistant_turn',
      ]),
    );
    expect(t.events.find(e => e.type === 'user_turn')).toMatchObject({
      conversationId: 'chat-1',
      text: fixture('en-us-capital').text,
    });
    expect(t.engine.latency?.turns).toBe(1);
    await t.engine.setAudioOutput('earpiece');
    expect(t.events[t.events.length - 1]).toMatchObject({
      type: 'route',
      route: 'earpiece',
    });
    t.engine.stopVoiceMode();
    await t.clock.advance(100);
    expect(t.engine.voiceMode).toEqual({status: 'off'});
    expect(t.events.some(e => e.type === 'voice_mode_stopped')).toBe(true);
    await t.clock.advance(6000);
    expect(t.sttReleases()).toBe(1);
    expect(t.tts.released).toBe(1);
  });

  it('does not start where the memory plan refuses it', async () => {
    const t = setup({voiceModeAvailable: false});
    expect(t.engine.voiceModeAvailable).toBe(false);
    await t.engine.startVoiceMode(null);
    expect(t.engine.voiceMode).toEqual({status: 'off'});
    expect(t.engine.latency).toBeNull();
    await t.engine.resumeVoiceMode();
  });
});
