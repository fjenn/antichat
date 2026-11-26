import {LatencyTracker, breakdown, percentile} from '../latency/tracker';
import {EchoGuard} from '../mode/echo';
import {planVoiceMemory, WHISPER_RUNTIME_BYTES} from '../mode/memoryPolicy';
import type {SttChoice} from '../stt/select';
import {SYSTEM_VOICE, findVoice} from '../tts/voices';

const whisper = (tier: 'base' | 'small' = 'base'): SttChoice => ({
  adapter: 'whisper',
  whisperTier: tier,
  needsDownload: false,
  reason: 'whisper_default',
});
const system: SttChoice = {
  adapter: 'system',
  needsDownload: false,
  reason: 'system_streaming',
};
const kokoro = findVoice('kokoro:af_heart')!;
const phonon = findVoice('phonon:Juniper')!;

describe('planVoiceMemory', () => {
  it('class A: system recogniser and system voice only, or no voice mode', () => {
    const plan = planVoiceMemory({
      deviceClass: 'A',
      platform: 'ios',
      stt: whisper(),
      voice: kokoro,
      systemSttAvailable: true,
    });
    expect(plan).toMatchObject({
      voiceMode: 'system_only',
      stt: {adapter: 'system'},
      voice: SYSTEM_VOICE,
      sessionBytes: 0,
      dictationWarmMs: 0,
      downgrades: ['voice_to_system', 'stt_to_system'],
    });
    expect(
      planVoiceMemory({
        deviceClass: 'A',
        platform: 'android',
        stt: whisper(),
        voice: SYSTEM_VOICE,
        systemSttAvailable: false,
      }),
    ).toMatchObject({voiceMode: 'unavailable', reason: 'class_too_small'});
  });

  it('class B: Whisper base plus a small voice; Kokoro is swapped for the system voice', () => {
    const small = planVoiceMemory({
      deviceClass: 'B',
      platform: 'ios',
      stt: whisper(),
      voice: phonon,
      systemSttAvailable: false,
    });
    expect(small).toMatchObject({
      voiceMode: 'full',
      voice: phonon,
      dictationWarmMs: 0,
      downgrades: [],
    });
    expect(small.sessionBytes).toBe(
      WHISPER_RUNTIME_BYTES.base + 200 * 1024 * 1024,
    );
    const big = planVoiceMemory({
      deviceClass: 'B',
      platform: 'ios',
      stt: whisper(),
      voice: kokoro,
      systemSttAvailable: false,
    });
    expect(big).toMatchObject({
      voiceMode: 'full',
      voice: SYSTEM_VOICE,
      downgrades: ['voice_to_system'],
    });
  });

  it('class C and up keep the models warm after use', () => {
    const c = planVoiceMemory({
      deviceClass: 'C',
      platform: 'android',
      stt: whisper(),
      voice: kokoro,
      systemSttAvailable: false,
    });
    expect(c).toMatchObject({
      voiceMode: 'full',
      voice: kokoro,
      dictationWarmMs: 30_000,
      voiceWarmMs: 60_000,
    });
    expect(c.sessionBytes).toBe(330_000_000 + 350_000_000);
    const e = planVoiceMemory({
      deviceClass: 'E',
      platform: 'ios',
      stt: whisper('small'),
      voice: kokoro,
      systemSttAvailable: true,
    });
    expect(e).toMatchObject({dictationWarmMs: 120_000, voiceWarmMs: 300_000});
    expect(e.sessionBytes).toBe(650_000_000 + 500_000_000);
  });

  it('system recogniser and system voice cost nothing', () => {
    expect(
      planVoiceMemory({
        deviceClass: 'C',
        platform: 'ios',
        stt: system,
        voice: SYSTEM_VOICE,
        systemSttAvailable: true,
      }),
    ).toMatchObject({voiceMode: 'system_only', sessionBytes: 0});
  });

  it('measured free memory wins: voice first, then recogniser, then refusal', () => {
    const tight = planVoiceMemory({
      deviceClass: 'C',
      platform: 'ios',
      stt: whisper(),
      voice: kokoro,
      systemSttAvailable: true,
      freeBytes: 700_000_000,
    });
    expect(tight).toMatchObject({
      voiceMode: 'full',
      voice: SYSTEM_VOICE,
      stt: {adapter: 'whisper'},
      downgrades: ['voice_to_system'],
    });
    const tighter = planVoiceMemory({
      deviceClass: 'D',
      platform: 'ios',
      stt: whisper('small'),
      voice: kokoro,
      systemSttAvailable: false,
      freeBytes: 600_000_000,
    });
    expect(tighter).toMatchObject({
      voiceMode: 'full',
      stt: {whisperTier: 'base'},
    });
    const none = planVoiceMemory({
      deviceClass: 'C',
      platform: 'ios',
      stt: whisper(),
      voice: kokoro,
      systemSttAvailable: true,
      freeBytes: 200_000_000,
    });
    expect(none).toMatchObject({
      voiceMode: 'system_only',
      stt: {adapter: 'system'},
    });
    expect(
      planVoiceMemory({
        deviceClass: 'C',
        platform: 'android',
        stt: whisper(),
        voice: kokoro,
        systemSttAvailable: false,
        freeBytes: 200_000_000,
      }),
    ).toMatchObject({voiceMode: 'unavailable', reason: 'out_of_memory'});
  });
});

describe('LatencyTracker', () => {
  it('splits a turn into stages that add up', () => {
    const parts = breakdown({
      speechEnd: 1000,
      endpoint: 1700,
      sttFinal: 2100,
      firstSentence: 2900,
      firstAudio: 3150,
    });
    expect(parts).toEqual({
      endpointingMs: 700,
      sttMs: 400,
      llmFirstSentenceMs: 800,
      ttsFirstAudioMs: 250,
      totalMs: 2150,
    });
  });

  it('speculation: stages finished before the endpoint cost nothing', () => {
    const parts = breakdown({
      speechEnd: 1000,
      endpoint: 1700,
      sttFinal: 1450,
      firstSentence: 1650,
      firstAudio: 1900,
    })!;
    expect(parts).toEqual({
      endpointingMs: 700,
      sttMs: 0,
      llmFirstSentenceMs: 0,
      ttsFirstAudioMs: 200,
      totalMs: 900,
    });
    expect(breakdown({speechEnd: 1, endpoint: 2})).toBeNull();
  });

  it('collects turns and summarises p50 / p90', () => {
    const tracker = new LatencyTracker();
    expect(tracker.complete()).toBeNull();
    for (const total of [1000, 1200, 1400, 3000]) {
      tracker.begin();
      tracker.setSpeculation('adopted');
      tracker.mark('speechEnd', 0);
      tracker.mark('endpoint', 700);
      tracker.mark('sttFinal', 800);
      tracker.mark('firstToken', 900);
      tracker.mark('firstToken', 5000); // only the first counts
      tracker.mark('firstSentence', total - 100);
      tracker.mark('firstAudio', total);
      expect(tracker.complete()).toMatchObject({
        totalMs: total,
        firstTokenMs: 100,
        speculation: 'adopted',
      });
    }
    const summary = tracker.summary();
    expect(summary.turns).toBe(4);
    expect(summary.totalMs.p50).toBe(1300);
    expect(summary.totalMs.p90).toBe(2520);
    expect(summary.endpointingMs).toEqual({p50: 700, p90: 700});
    tracker.recordBargeIn({detectMs: 300, stopMs: 60});
    expect(tracker.bargeIns).toHaveLength(1);
    expect(percentile([], 0.5)).toBeNaN();
  });
});

describe('EchoGuard', () => {
  it('tells an echoed transcript from a real one', () => {
    const spoken =
      'Paris is the capital of France. About two million people live in the city itself.';
    expect(
      EchoGuard.isEchoTranscript(
        'about two million people live in the city',
        spoken,
      ),
    ).toBe(true);
    expect(EchoGuard.isEchoTranscript('The capital of France.', spoken)).toBe(
      true,
    );
    expect(
      EchoGuard.isEchoTranscript('How many people live in Berlin?', spoken),
    ).toBe(false);
    expect(EchoGuard.isEchoTranscript('Paris', spoken)).toBe(false);
    expect(
      EchoGuard.isEchoTranscript(
        'Tell me more about the city of Lyon and its food',
        spoken,
      ),
    ).toBe(false);
    expect(EchoGuard.isEchoTranscript('anything', '')).toBe(false);
  });

  it('learns the echo level and asks a talker to be clearly louder', () => {
    const guard = new EchoGuard({hardwareAec: true, route: 'speaker'});
    expect(guard.gateDb(0)).toBe(-100);
    guard.playbackStarted(1000);
    expect(guard.gateDb(1100)).toBe(0); // calibrating: nothing passes
    for (let t = 1000; t < 1600; t += 50) {
      guard.observe(-50, t, 50);
    }
    expect(guard.gateDb(1700)).toBe(-42);
    // A short louder burst is echo: the estimate follows it.
    guard.observe(-40, 1700, 50);
    guard.observe(-40, 1750, 50);
    guard.observe(-60, 1800, 50);
    guard.observe(-60, 1850, 50);
    expect(guard.gateDb(1900)).toBe(-32);
    // A long loud stretch is a talker: the estimate holds.
    for (let t = 1900; t < 2400; t += 50) {
      guard.observe(-20, t, 50);
    }
    expect(guard.gateDb(2400)).toBe(-32);
    guard.playbackStopped(2400);
    expect(guard.active(2500)).toBe(true);
    expect(guard.active(2800)).toBe(false);
    expect(guard.gateDb(2800)).toBe(-100);
    // The next answer starts from what was learned, with a short calibration.
    guard.playbackStarted(5000);
    expect(guard.gateDb(5400)).toBe(-32);
  });

  it('never learns more than a canceller could leave, and forgets on a new route', () => {
    const guard = new EchoGuard({hardwareAec: true, route: 'speaker'});
    guard.playbackStarted(0);
    guard.observe(-10, 100, 50); // the user talks during calibration
    expect(guard.gateDb(700)).toBe(-27);
    guard.setRoute('bluetooth');
    expect(guard.gateDb(700)).toBe(-100);
    expect(guard.halfDuplex).toBe(false);
    guard.setRoute('speaker', false);
    expect(guard.halfDuplex).toBe(true);
    expect(guard.minBargeInMs).toBe(300);
  });
});
