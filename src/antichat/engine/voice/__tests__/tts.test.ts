import {FakeTts, VirtualClock} from '../harness/fakes';
import {routeFromPort} from '../session/route';
import {ReadAloudPlayer, type ReadAloudState} from '../tts/readAloud';
import {StreamingSpeaker, type SpeakerEvent} from '../tts/streamingSpeaker';
import {UnitTracker} from '../tts/unitTracker';
import {
  CURATED_VOICES,
  SYSTEM_VOICE,
  TTS_ENGINES,
  defaultVoice,
  findVoice,
  voiceCost,
  voicesFor,
  type VoiceFacts,
} from '../tts/voices';

const facts = (over: Partial<VoiceFacts> = {}): VoiceFacts => ({
  deviceClass: 'C',
  platform: 'ios',
  language: 'en-US',
  phononSupported: true,
  installedEngines: [],
  ...over,
});

describe('voice catalogue', () => {
  it('class A only ever gets the system voice', () => {
    expect(voicesFor(facts({deviceClass: 'A'})).map(v => v.id)).toEqual([
      'system:default',
    ]);
    expect(defaultVoice(facts({deviceClass: 'A'}))).toEqual({
      voice: SYSTEM_VOICE,
    });
  });

  it('class B: Phonon where supported, else Kitten; never Kokoro', () => {
    const withPhonon = defaultVoice(facts({deviceClass: 'B'}));
    expect(withPhonon.voice).toBe(SYSTEM_VOICE);
    expect(withPhonon.offer?.voice.engine).toBe('phonon');
    expect(withPhonon.offer?.downloadBytes).toBe(171_554_733);
    const without = defaultVoice(
      facts({deviceClass: 'B', phononSupported: false, platform: 'android'}),
    );
    expect(without.offer?.voice.engine).toBe('kitten');
    expect(without.offer?.downloadBytes).toBe(57 * 1024 * 1024);
    expect(
      voicesFor(facts({deviceClass: 'B'})).some(v => v.engine === 'kokoro'),
    ).toBe(false);
  });

  it('class C and up: the installed neural voice speaks, no offer', () => {
    const choice = defaultVoice(facts({installedEngines: ['phonon']}));
    expect(choice.voice.engine).toBe('phonon');
    expect(choice.offer).toBeUndefined();
    const kokoro = defaultVoice(
      facts({phononSupported: false, installedEngines: ['kokoro']}),
    );
    expect(kokoro.voice.id).toBe('kokoro:af_heart');
  });

  it('an installed lesser voice speaks while the better one is offered', () => {
    const choice = defaultVoice(facts({installedEngines: ['kokoro']}));
    expect(choice.voice.engine).toBe('kokoro');
    expect(choice.offer?.voice.engine).toBe('phonon');
  });

  it('other languages: Supertonic on C+, the system voice below', () => {
    expect(defaultVoice(facts({language: 'de-DE'})).offer?.voice.engine).toBe(
      'supertonic',
    );
    expect(defaultVoice(facts({language: 'de-DE', deviceClass: 'B'}))).toEqual({
      voice: SYSTEM_VOICE,
    });
    expect(voicesFor(facts({language: 'sw'})).map(v => v.engine)).toEqual([
      'system',
    ]);
  });

  it('sizes come per platform', () => {
    expect(
      voiceCost(findVoice('kokoro:af_heart')!, 'android').downloadBytes,
    ).toBe(107 * 1024 * 1024);
    expect(voiceCost(findVoice('kokoro:af_heart')!, 'ios').runtimeBytes).toBe(
      500_000_000,
    );
    expect(voiceCost(SYSTEM_VOICE, 'ios')).toEqual({
      downloadBytes: 0,
      runtimeBytes: 0,
    });
    for (const voice of CURATED_VOICES) {
      expect(TTS_ENGINES[voice.engine]).toBeDefined();
      expect(voice.id).toBe(
        `${voice.engine}:${voice.engineVoiceId || 'default'}`,
      );
    }
  });
});

describe('StreamingSpeaker', () => {
  function setup(timings = {}) {
    const clock = new VirtualClock();
    const tts = new FakeTts(clock, {
      prepareMs: 0,
      firstAudioMs: 200,
      gapMs: 0,
      msPerChar: 10,
      stopMs: 30,
      ...timings,
    });
    const speaker = new StreamingSpeaker(
      tts,
      {voice: SYSTEM_VOICE, language: 'en'},
      {clock},
    );
    const events: SpeakerEvent[] = [];
    speaker.events.on(e => events.push(e));
    return {clock, tts, speaker, events};
  }

  it('starts speaking the first sentence while the rest is still being written', async () => {
    const {clock, tts, speaker, events} = setup();
    speaker.push('The capital is **Paris**. ');
    await clock.advance(50);
    expect(tts.log).toHaveLength(0); // sentence held until the next begins
    speaker.push('It');
    await clock.advance(250);
    expect(tts.log.map(l => l.text)).toEqual(['The capital is Paris.']);
    expect(events.find(e => e.type === 'first_unit')?.atMs).toBe(50);
    expect(events.find(e => e.type === 'unit_start')?.atMs).toBe(250);
    speaker.push(' has 2 million people.\n\n```js\ncode()\n```\nBye 👋');
    const done = speaker.finish();
    await clock.advance(5000);
    await expect(done).resolves.toBe('finished');
    expect(tts.log.map(l => l.text)).toEqual([
      'The capital is Paris.',
      'It has 2 million people.',
      'Here is a code example.',
      'Bye',
    ]);
    expect(speaker.heardText).toBe(speaker.spokenText);
  });

  it('stop silences at once and reports what was heard', async () => {
    const {clock, tts, speaker} = setup();
    speaker.push('First sentence here. Second sentence here. Third one.');
    speaker.finish();
    await clock.advance(200 + 210 + 100); // into the second sentence
    expect(tts.playing).toBe(true);
    const stopping = speaker.stop();
    await clock.advance(30);
    await stopping;
    expect(tts.playing).toBe(false);
    expect(speaker.heardText).toBe('First sentence here.');
    await clock.advance(3000);
    expect(tts.log).toHaveLength(2);
    speaker.push('ignored');
  });

  it('reports a failing voice', async () => {
    const {clock, tts, speaker, events} = setup();
    tts.failSpeak.add('system');
    speaker.push('Hello there. More.');
    const done = speaker.finish();
    await clock.advance(1000);
    await expect(done).resolves.toBe('failed');
    expect(events.some(e => e.type === 'error')).toBe(true);
  });

  it('applies pronunciation fixes', async () => {
    const {clock, tts, speaker} = setup();
    speaker.push('The API is ready.');
    speaker.finish();
    await clock.advance(1000);
    expect(tts.log[0]!.text).toBe('The A P I is ready.');
  });
});

describe('ReadAloudPlayer', () => {
  const text = 'One is first. Two is second. Three is third. Four is last.';

  function setup() {
    const clock = new VirtualClock();
    const tts = new FakeTts(clock, {
      prepareMs: 100,
      firstAudioMs: 100,
      gapMs: 0,
      msPerChar: 20,
      stopMs: 10,
    });
    const keeper = {
      holds: 0,
      hold: async () => {
        keeper.holds++;
      },
      release: () => {
        keeper.holds--;
      },
    };
    const player = new ReadAloudPlayer({
      backend: tts,
      keeper,
      voice: () => SYSTEM_VOICE,
    });
    const states: ReadAloudState[] = [];
    player.changes.on(s => states.push(s));
    return {clock, tts, keeper, player, states};
  }

  it('plays sentence by sentence to the end and releases the keeper', async () => {
    const {clock, tts, keeper, player, states} = setup();
    player.play('m1', text, {language: 'en'});
    await clock.advance(50);
    expect(player.state).toEqual({status: 'preparing', messageId: 'm1'});
    expect(keeper.holds).toBe(1);
    await clock.advance(200);
    expect(player.state).toMatchObject({
      status: 'speaking',
      index: 0,
      count: 4,
      rate: 1,
    });
    await clock.advance(10_000);
    expect(player.state).toEqual({status: 'idle'});
    expect(keeper.holds).toBe(0);
    expect(tts.log.map(l => l.text)).toEqual([
      'One is first.',
      'Two is second.',
      'Three is third.',
      'Four is last.',
    ]);
    const progress = states.flatMap(s => ('progress' in s ? [s.progress] : []));
    expect(progress).toEqual([...progress].sort((a, b) => a - b));
    expect(progress[progress.length - 1]).toBe(1);
  });

  it('pauses and resumes in place', async () => {
    const {clock, tts, player} = setup();
    player.play('m1', text);
    await clock.advance(300);
    player.pause();
    expect(player.state.status).toBe('paused');
    await clock.advance(5000);
    expect(tts.log).toHaveLength(1);
    expect(tts.log[0]!.endedAt).toBeUndefined();
    player.resume();
    await clock.advance(10_000);
    expect(tts.log).toHaveLength(4);
    expect(player.state.status).toBe('idle');
  });

  it('seeks by sentence, also while paused', async () => {
    const {clock, tts, player} = setup();
    player.play('m1', text);
    await clock.advance(300);
    player.seekTo(2);
    await clock.advance(150);
    expect(player.state).toMatchObject({status: 'speaking', index: 2});
    expect(tts.log[tts.log.length - 1]!.text).toBe('Three is third.');
    player.pause();
    player.previous();
    expect(player.state).toMatchObject({status: 'paused', index: 1});
    player.next();
    player.next();
    player.next();
    expect(player.state).toMatchObject({status: 'paused', index: 3});
    player.resume();
    await clock.advance(5000);
    expect(tts.log[tts.log.length - 1]!.text).toBe('Four is last.');
    expect(player.state.status).toBe('idle');
  });

  it('changes speed from the current sentence on', async () => {
    const {clock, tts, player} = setup();
    player.play('m1', text);
    await clock.advance(300);
    player.setRate(2);
    await clock.advance(150);
    expect(player.rate).toBe(2);
    expect(tts.log[tts.log.length - 1]).toMatchObject({
      text: 'One is first.',
      rate: 2,
    });
    player.setRate(9);
    expect(player.rate).toBe(2);
    player.setRate(0.1);
    expect(player.rate).toBe(0.5);
  });

  it('keeps playing when nothing tells it to stop (screen lock), pauses for a call', async () => {
    const {clock, keeper, player} = setup();
    player.play('m1', text);
    await clock.advance(400);
    // A lock is not an event the player reacts to: the keeper stays held.
    expect(keeper.holds).toBe(1);
    expect(player.state.status).toBe('speaking');
    player.handleInterruption({type: 'began'});
    expect(player.state.status).toBe('paused');
    player.handleInterruption({type: 'ended', shouldResume: true});
    expect(player.state.status).toBe('speaking');
    player.pause(); // the user paused: a call ending must not resume it
    player.handleInterruption({type: 'began'});
    player.handleInterruption({type: 'ended', shouldResume: true});
    expect(player.state.status).toBe('paused');
    const stopping = player.stop();
    await clock.advance(50);
    await stopping;
    expect(keeper.holds).toBe(0);
  });

  it('a second play replaces the first; empty text does nothing', async () => {
    const {clock, tts, player} = setup();
    player.play('m1', text);
    await clock.advance(300);
    player.play('m2', 'Only this.');
    await clock.advance(2000);
    expect(tts.log[tts.log.length - 1]!.text).toBe('Only this.');
    await player.play('m3', '🙂 ---');
    expect(player.state.status).toBe('idle');
  });

  it('reports a voice that fails to load', async () => {
    const {clock, tts, keeper, player} = setup();
    const errors: unknown[] = [];
    player.errors.on(e => errors.push(e));
    tts.failPrepare.add('system');
    player.play('m1', text);
    await clock.advance(500);
    expect(errors).toHaveLength(1);
    expect(player.state.status).toBe('idle');
    expect(keeper.holds).toBe(0);
  });
});

describe('UnitTracker', () => {
  it('maps stream ranges back to units, in order', () => {
    const log: string[] = [];
    const tracker = new UnitTracker({
      onUnitStart: id => log.push(`start ${id}`),
      onUnitEnd: id => log.push(`end ${id}`),
      onError: () => {},
    });
    expect(tracker.add(0, 'One.')).toBe('One. ');
    tracker.add(1, 'Two is here.');
    tracker.add(2, 'Three.');
    tracker.progress(0, 5); // first chunk: unit 0
    tracker.progress(5, 25); // second chunk holds units 1 and 2
    expect(log).toEqual(['start 0', 'end 0', 'start 1', 'start 2']);
    tracker.drain();
    expect(log).toEqual([
      'start 0',
      'end 0',
      'start 1',
      'start 2',
      'end 1',
      'end 2',
    ]);
    tracker.drain();
    expect(log).toHaveLength(6);
  });

  it('drain starts and ends units no progress event mentioned', () => {
    const log: string[] = [];
    const tracker = new UnitTracker({
      onUnitStart: id => log.push(`start ${id}`),
      onUnitEnd: id => log.push(`end ${id}`),
      onError: () => {},
    });
    tracker.add(0, 'Only.');
    tracker.drain();
    expect(log).toEqual(['start 0', 'end 0']);
  });
});

describe('routeFromPort', () => {
  it('names the routes of both platforms', () => {
    expect(routeFromPort('Speaker')).toBe('speaker');
    expect(routeFromPort('Receiver')).toBe('earpiece');
    expect(routeFromPort('BluetoothHFP')).toBe('bluetooth');
    expect(routeFromPort('BluetoothA2DPOutput')).toBe('bluetooth');
    expect(routeFromPort('Headphones')).toBe('wired');
    expect(routeFromPort('USBAudio')).toBe('wired');
    expect(routeFromPort('CarAudio')).toBe('car');
    expect(routeFromPort('earpiece')).toBe('earpiece');
    expect(routeFromPort(undefined)).toBe('unknown');
    expect(routeFromPort('HDMI')).toBe('unknown');
  });
});
