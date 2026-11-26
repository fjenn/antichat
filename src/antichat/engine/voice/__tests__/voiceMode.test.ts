import {SystemSttAdapter} from '../stt/systemAdapter';
import {FakeSystemRecognizer, voicedSamples} from '../harness/fakes';
import {fixture, fixturePcm} from '../harness/fixtures';
import {DEFAULT_REPLY, VoiceRig} from '../harness/rig';
import {findVoice} from '../tts/voices';
import {transition} from '../mode/machine';

describe('voice mode state machine', () => {
  it('only allows the documented transitions', () => {
    expect(transition('off', 'START')).toBe('starting');
    expect(transition('starting', 'READY')).toBe('listening');
    expect(transition('listening', 'TURN_ENDED')).toBe('thinking');
    expect(transition('thinking', 'FIRST_AUDIO')).toBe('speaking');
    expect(transition('speaking', 'REPLY_DONE')).toBe('listening');
    expect(transition('speaking', 'BARGE_IN')).toBe('listening');
    expect(transition('thinking', 'BARGE_IN')).toBe('listening');
    expect(transition('speaking', 'INTERRUPTION_BEGAN')).toBe('paused');
    expect(transition('paused', 'INTERRUPTION_ENDED')).toBe('listening');
    expect(transition('listening', 'BARGE_IN')).toBeNull();
    expect(transition('off', 'TURN_ENDED')).toBeNull();
    expect(transition('paused', 'TURN_ENDED')).toBeNull();
    for (const phase of [
      'starting',
      'listening',
      'thinking',
      'speaking',
      'paused',
    ] as const) {
      expect(transition(phase, 'STOP')).toBe('off');
    }
  });
});

describe('voice mode', () => {
  it('five hands-free turns land in the thread, with a latency budget each', async () => {
    const rig = new VoiceRig();
    await rig.start('chat-7');
    expect(rig.session.activations).toEqual(['conversation']);
    expect(rig.mic.options).toEqual({echoCancellation: true});
    expect(rig.keepAwake.holds).toBe(1);

    const ids = [
      'en-us-capital',
      'en-gb-timer',
      'en-au-plants',
      'en-in-recipe',
      'en-ie-trip',
    ];
    for (const id of ids) {
      await rig.turn(id);
    }
    expect(rig.phases).toEqual([
      'starting',
      'listening',
      ...ids.flatMap(() => ['thinking', 'speaking', 'listening']),
    ]);
    expect(
      rig.chat.thread.filter(m => m.role === 'user').map(m => m.text),
    ).toEqual(ids.map(id => fixture(id).text));
    expect(
      rig.chat.thread.filter(m => m.role === 'assistant').map(m => m.text),
    ).toEqual(ids.map(() => DEFAULT_REPLY));
    expect(rig.chat.sends.concat([]).every(s => s.options.spoken)).toBe(true);
    expect(rig.of('user_turn')).toHaveLength(5);
    expect(rig.of('assistant_done').every(e => e.status === 'complete')).toBe(
      true,
    );
    expect(rig.of('assistant_done')[0]!.heardText).toBe(DEFAULT_REPLY);

    const turns = rig.of('latency').map(e => e.turn);
    expect(turns).toHaveLength(5);
    for (const turn of turns) {
      expect(
        turn.endpointingMs +
          turn.sttMs +
          turn.llmFirstSentenceMs +
          turn.ttsFirstAudioMs,
      ).toBe(turn.totalMs);
      expect(turn.endpointingMs).toBeGreaterThanOrEqual(700);
      expect(turn.endpointingMs).toBeLessThan(800);
      expect(turn.ttsFirstAudioMs).toBeGreaterThanOrEqual(180);
    }
    expect(rig.controller.latency.summary().turns).toBe(5);

    await rig.controller.stop();
    expect(rig.controller.phase).toBe('off');
    expect(rig.keepAwake.holds).toBe(0);
    expect(rig.session.profile).toBeNull();
    expect(rig.mic.running).toBe(false);
    expect(rig.of('stopped')).toEqual([{type: 'stopped', reason: 'user'}]);
  });

  it('shows the live transcript while the user speaks', async () => {
    const rig = new VoiceRig();
    await rig.start();
    await rig.say('en-ie-trip');
    const partials = rig.of('partial');
    expect(partials.length).toBeGreaterThanOrEqual(2);
    expect(fixture('en-ie-trip').text.startsWith(partials[0]!.text)).toBe(true);
    expect(rig.of('level').some(e => e.level > 0.3)).toBe(true);
  });

  it('barge-in: speaking over the answer stops it within half a second', async () => {
    const rig = new VoiceRig({
      chat: {msPerWord: 250},
      reply: () =>
        'Italy is a country in southern Europe. It is shaped like a boot. Rome is its capital. It is famous for food.',
    });
    await rig.start();
    await rig.say('en-us-capital');
    await rig.until('speaking');
    await rig.quiet(1500); // well into the first sentence, echo present
    expect(rig.tts.playing).toBe(true);
    const from = rig.clock.now();
    await rig.say('en-us-bargein');
    const barge = rig.of('barge_in')[0]!;
    expect(barge.by).toBe('voice');
    // Detection needs 300 ms of speech; silencing the speaker takes the rest.
    expect(barge.detectMs).toBeGreaterThanOrEqual(300);
    expect(barge.detectMs + barge.stopMs).toBeLessThan(500);
    const silentAt = rig.tts.log[rig.tts.log.length - 1]!;
    expect(silentAt.endedAt).toBeUndefined();
    expect(rig.clock.now() - from).toBeGreaterThan(0);
    // Generation was stopped too, and the thread keeps the partial answer.
    const answers = rig.chat.thread.filter(m => m.role === 'assistant');
    expect(answers[0]!.status).toBe('stopped');
    expect(rig.of('assistant_done')[0]).toMatchObject({status: 'interrupted'});
    // The interrupting words open the next turn in full.
    await rig.until('speaking');
    expect(rig.of('user_turn').map(e => e.text)).toEqual([
      fixture('en-us-capital').text,
      fixture('en-us-bargein').text,
    ]);
    expect(rig.controller.latency.bargeIns).toHaveLength(1);
  });

  it('the button interrupts too, also while thinking', async () => {
    const rig = new VoiceRig({chat: {firstTokenMs: 3000}});
    await rig.start();
    await rig.say('en-us-capital');
    await rig.until('thinking');
    rig.controller.interrupt();
    expect(rig.controller.phase).toBe('listening');
    expect(rig.of('barge_in')[0]).toMatchObject({by: 'button'});
    await rig.quiet(4000);
    expect(rig.tts.log).toHaveLength(0);
    rig.controller.interrupt(); // nothing to interrupt
    expect(rig.of('barge_in')).toHaveLength(1);
  });

  describe('echo', () => {
    it('with echo cancellation, the answer never comes back as a user turn', async () => {
      const rig = new VoiceRig({echoGain: 0.08});
      await rig.start();
      for (const id of ['en-us-capital', 'en-gb-timer', 'en-au-plants']) {
        await rig.turn(id);
        await rig.quiet(1500);
      }
      expect(rig.of('barge_in')).toHaveLength(0);
      expect(rig.of('user_turn')).toHaveLength(3);
      expect(rig.chat.thread).toHaveLength(6);
      expect(rig.of('assistant_done').every(e => e.status === 'complete')).toBe(
        true,
      );
    });

    it('even a loud residual echo does not trip barge-in, but the user still can', async () => {
      const rig = new VoiceRig({
        echoGain: 0.15,
        reply: () => DEFAULT_REPLY + ' ' + DEFAULT_REPLY,
      });
      await rig.start();
      await rig.say('en-us-capital');
      await rig.until('speaking');
      await rig.quiet(3000);
      expect(rig.of('barge_in')).toHaveLength(0);
      await rig.say('en-us-bargein');
      expect(rig.of('barge_in')).toHaveLength(1);
    });

    it('loudspeaker without echo cancellation: half-duplex, only the button interrupts', async () => {
      const rig = new VoiceRig({echoCancellation: false, echoGain: 1});
      await rig.start();
      expect(rig.of('route')[0]).toEqual({
        type: 'route',
        route: 'speaker',
        halfDuplex: true,
      });
      await rig.say('en-us-capital');
      await rig.until('speaking');
      await rig.say('en-us-bargein'); // drowned in our own voice: ignored
      expect(rig.of('barge_in')).toHaveLength(0);
      await rig.until('listening');
      await rig.quiet(2000);
      expect(rig.of('user_turn')).toHaveLength(1);
      rig.controller.interrupt();
    });

    it('headphones without echo cancellation keep voice barge-in', async () => {
      const rig = new VoiceRig({
        echoCancellation: false,
        route: 'bluetooth',
        echoGain: 0,
      });
      await rig.start();
      expect(rig.of('route')[0]).toMatchObject({halfDuplex: false});
      await rig.say('en-us-capital');
      await rig.until('speaking');
      await rig.quiet(500);
      await rig.say('en-us-bargein');
      expect(rig.of('barge_in')).toHaveLength(1);
    });

    it('a transcript that repeats the answer is dropped (last line of defence)', async () => {
      const rig = new VoiceRig({echoGain: 0});
      await rig.start();
      await rig.turn('en-us-capital');
      // The recogniser "hears" the assistant's own sentence.
      await rig.say(
        'en-gb-timer',
        'About two million people live in the city itself',
      );
      await rig.quiet(3000);
      expect(rig.of('user_turn')).toHaveLength(1);
      expect(rig.chat.thread).toHaveLength(2);
      expect(rig.controller.phase).toBe('listening');
    });
  });

  describe('speculative generation', () => {
    const slowStt = (audioMs: number) => 150 + audioMs * 0.05;

    it('starts the reply at the first pause and adopts it when the turn ends there', async () => {
      const rig = new VoiceRig({sttDecodeMs: () => 100});
      await rig.start();
      await rig.turn('en-us-capital');
      expect(rig.chat.speculations).toBe(1);
      expect(rig.chat.adopted).toBe(1);
      expect(rig.chat.sends).toHaveLength(0);
      expect(rig.chat.thread.map(m => m.role)).toEqual(['user', 'assistant']);
      expect(rig.of('latency')[0]!.turn.speculation).toBe('adopted');
    });

    it('drops the speculation silently when the user keeps talking', async () => {
      const rig = new VoiceRig({sttDecodeMs: () => 60});
      await rig.start();
      await rig.say('en-us-bargein', 'Wait stop');
      await rig.quiet(450); // a pause, but not the end
      expect(rig.chat.speculations).toBe(1);
      await rig.say('en-us-capital', 'Wait stop what is the capital of France');
      expect(rig.chat.cancelled).toBe(1);
      expect(rig.chat.thread).toHaveLength(0); // nothing was written
      await rig.until('speaking');
      expect(rig.chat.thread[0]!.text).toBe(
        'Wait stop what is the capital of France',
      );
      expect(rig.tts.log.every(l => l.startedAt > 0)).toBe(true);
    });

    it('measurably cuts time to first audio', async () => {
      const run = async (
        speculativeMs: number,
        sttDecodeMs: (ms: number) => number,
      ) => {
        const rig = new VoiceRig({config: {speculativeMs}, sttDecodeMs});
        await rig.start();
        for (const id of [
          'en-gb-timer',
          'en-au-plants',
          'en-in-recipe',
          'en-ie-trip',
        ]) {
          await rig.turn(id);
        }
        return {
          summary: rig.controller.latency.summary(),
          adopted: rig.chat.adopted,
        };
      };
      // A recogniser that answers within the pause: the reply itself starts early.
      const fast = (audioMs: number) => 80 + audioMs * 0.02;
      const off = await run(0, fast);
      const on = await run(300, fast);
      expect(off.summary.turns).toBe(4);
      expect(on.adopted).toBeGreaterThanOrEqual(3);
      expect(on.summary.totalMs.p50).toBeLessThan(
        off.summary.totalMs.p50 - 300,
      );
      // A slow one: the reply cannot start early, but its decode overlaps the wait.
      const slowOff = await run(0, slowStt);
      const slowOn = await run(300, slowStt);
      expect(slowOn.summary.totalMs.p50).toBeLessThan(
        slowOff.summary.totalMs.p50 - 100,
      );
      expect(slowOn.summary.sttMs.p50).toBeLessThan(slowOff.summary.sttMs.p50);
    });

    it('is off without a chat port that supports it', async () => {
      const rig = new VoiceRig({noSpeculation: true});
      await rig.start();
      await rig.turn('en-us-capital');
      expect(rig.chat.speculations).toBe(0);
      expect(rig.of('latency')[0]!.turn.speculation).toBe('off');
    });
  });

  describe('timeouts and recovery', () => {
    it('ends the session after a long silence', async () => {
      const rig = new VoiceRig({config: {idleTimeoutMs: 5000}});
      await rig.start();
      await rig.quiet(5200);
      expect(rig.controller.phase).toBe('off');
      expect(rig.of('stopped')[0]).toEqual({
        type: 'stopped',
        reason: 'idle_timeout',
      });
    });

    it('a reply that never starts is dropped and listening goes on', async () => {
      const rig = new VoiceRig({
        config: {replyTimeoutMs: 2000, speculativeMs: 0},
      });
      await rig.start();
      rig.chat.failNext = 'hang';
      await rig.say('en-us-capital');
      await rig.quiet(3500);
      expect(rig.controller.phase).toBe('listening');
      expect(rig.of('error')[0]).toMatchObject({
        stage: 'reply',
        fatal: false,
        error: {code: 'timeout'},
      });
      await rig.turn('en-gb-timer');
      expect(rig.of('assistant_done')).toHaveLength(1);
    });

    it('a failing model or recogniser three times in a row ends the session', async () => {
      const rig = new VoiceRig({config: {speculativeMs: 0}});
      await rig.start();
      for (let i = 0; i < 3; i++) {
        rig.chat.failNext = 'error';
        await rig.say('en-us-capital');
        await rig.quiet(3000);
      }
      expect(rig.of('error').map(e => e.fatal)).toEqual([false, false, true]);
      expect(rig.of('error')[0]).toMatchObject({
        stage: 'reply',
        error: {code: 'failed'},
      });
      expect(rig.controller.phase).toBe('off');
      expect(rig.of('stopped')[0]).toMatchObject({reason: 'error'});

      const stt = new VoiceRig({config: {speculativeMs: 0}});
      await stt.start();
      stt.whisper.fail = true;
      await stt.say('en-us-capital');
      await stt.quiet(1500);
      expect(stt.of('error')[0]).toMatchObject({stage: 'stt', fatal: false});
      expect(stt.controller.phase).toBe('listening');
      stt.whisper.fail = false;
      await stt.turn('en-gb-timer');
      expect(stt.of('assistant_done')).toHaveLength(1);
    });

    it('a slow recogniser times out', async () => {
      const rig = new VoiceRig({
        config: {sttTimeoutMs: 1000, speculativeMs: 0},
        sttDecodeMs: () => 60_000,
      });
      await rig.start();
      await rig.say('en-us-capital');
      await rig.quiet(2500);
      expect(rig.of('error')[0]).toMatchObject({stage: 'stt'});
      expect(rig.controller.phase).toBe('listening');
    });

    it('restarts a silent microphone once, then gives up', async () => {
      const rig = new VoiceRig({config: {micWatchdogMs: 1000}});
      await rig.start();
      rig.mic.dead = true;
      await rig.quiet(1100);
      expect(rig.mic.started).toBe(2);
      await rig.quiet(1200);
      expect(rig.controller.phase).toBe('off');
      expect(rig.of('stopped')[0]).toMatchObject({reason: 'mic_lost'});
      expect(rig.of('error')[0]).toMatchObject({
        error: {code: 'mic_unavailable'},
        fatal: true,
      });
    });

    it('falls back to the system voice when the chosen one fails', async () => {
      const rig = new VoiceRig({
        config: {voice: findVoice('kokoro:af_heart')!},
      });
      rig.tts.failSpeak.add('kokoro');
      await rig.start();
      await rig.say('en-us-capital');
      await rig.until('listening');
      await rig.quiet(3000);
      expect(rig.of('voice_fallback')).toHaveLength(1);
      expect(rig.controller.phase).toBe('listening');
      await rig.turn('en-gb-timer');
      expect(rig.tts.log.every(l => l.voice === 'system:default')).toBe(true);
      expect(rig.tts.log.length).toBeGreaterThan(0);

      const load = new VoiceRig({
        config: {voice: findVoice('kokoro:af_heart')!},
      });
      load.tts.failPrepare.add('kokoro');
      await load.start();
      expect(load.controller.phase).toBe('listening');
      expect(load.of('voice_fallback')).toHaveLength(1);
    });

    it('does not start without microphone permission', async () => {
      const rig = new VoiceRig({permission: 'blocked'});
      await rig.start();
      expect(rig.controller.phase).toBe('off');
      expect(rig.of('error')[0]).toMatchObject({
        error: {code: 'permission_denied'},
        fatal: true,
      });
      expect(rig.mic.started).toBe(0);
    });
  });

  describe('audio session', () => {
    it('a phone call pauses the session and it resumes afterwards', async () => {
      const rig = new VoiceRig();
      await rig.start();
      await rig.say('en-us-capital');
      await rig.until('speaking');
      rig.session.fire({type: 'interruption_began'});
      await rig.clock.advance(100);
      expect(rig.controller.phase).toBe('paused');
      expect(rig.mic.running).toBe(false);
      expect(rig.tts.playing).toBe(false);
      expect(rig.chat.thread[1]!.status).toBe('stopped');
      await rig.quiet(2000);
      expect(rig.of('user_turn')).toHaveLength(1);
      rig.session.fire({type: 'interruption_ended', shouldResume: true});
      await rig.clock.advance(100);
      expect(rig.controller.phase).toBe('listening');
      expect(rig.mic.running).toBe(true);
      await rig.turn('en-gb-timer');
      expect(rig.of('user_turn')).toHaveLength(2);
    });

    it('stays paused when the system says not to resume, until the user does', async () => {
      const rig = new VoiceRig();
      await rig.start();
      rig.session.fire({type: 'interruption_began'});
      rig.session.fire({type: 'interruption_ended', shouldResume: false});
      await rig.clock.advance(100);
      expect(rig.controller.phase).toBe('paused');
      const resuming = rig.controller.resume();
      await rig.clock.advance(50);
      await resuming;
      expect(rig.controller.phase).toBe('listening');
    });

    it('follows route changes; pulling headphones stops the answer', async () => {
      const rig = new VoiceRig({
        echoCancellation: false,
        route: 'bluetooth',
        echoGain: 0,
      });
      await rig.start();
      await rig.say('en-us-capital');
      await rig.until('speaking');
      rig.session.changeRoute('speaker', 'device_removed');
      await rig.clock.advance(100);
      expect(rig.controller.phase).toBe('listening');
      expect(rig.tts.playing).toBe(false);
      expect(rig.of('route').map(e => [e.route, e.halfDuplex])).toEqual([
        ['bluetooth', false],
        ['speaker', true],
      ]);
      rig.session.changeRoute('wired', 'new_device');
      expect(rig.of('route')[2]).toMatchObject({
        route: 'wired',
        halfDuplex: false,
      });
    });
  });

  it('mute drops what the microphone hears; the answer still plays', async () => {
    const rig = new VoiceRig();
    await rig.start();
    rig.controller.setMuted(true);
    expect(rig.events[rig.events.length - 1]).toEqual({
      type: 'phase',
      phase: 'listening',
      muted: true,
    });
    await rig.say('en-us-capital');
    await rig.quiet(2000);
    expect(rig.of('user_turn')).toHaveLength(0);
    rig.controller.setMuted(false);
    await rig.say('en-gb-timer');
    await rig.until('speaking');
    rig.controller.setMuted(true);
    await rig.say('en-us-bargein'); // muted: no barge-in
    expect(rig.of('barge_in')).toHaveLength(0);
    await rig.until('listening');
    expect(rig.of('assistant_done')[0]).toMatchObject({status: 'complete'});
  });

  it('starts a new chat when none was given and reports its id', async () => {
    const rig = new VoiceRig();
    await rig.start(null);
    await rig.turn('en-us-capital');
    expect(rig.of('conversation')).toEqual([
      {type: 'conversation', conversationId: 'chat-1'},
    ]);
    expect(rig.controller.activeConversationId).toBe('chat-1');
    await rig.turn('en-gb-timer');
    expect(rig.chat.sends.concat([]).length + rig.chat.adopted).toBe(2);
    expect(rig.of('conversation')).toHaveLength(1);
  });

  it('runs on the system recogniser as well', async () => {
    const system = new FakeSystemRecognizer();
    const rig = new VoiceRig({
      stt: () => new SystemSttAdapter(system, async () => 'en-US'),
    });
    await rig.start();
    const id = 'en-au-plants';
    system.current = {
      text: fixture(id).text,
      language: 'en',
      voiced: voicedSamples(fixturePcm(id)),
    };
    await rig.turn(id);
    expect(rig.of('user_turn')[0]!.text).toBe(fixture(id).text);
    expect(rig.of('partial').length).toBeGreaterThan(4);
    expect(rig.of('latency')[0]!.turn.sttMs).toBe(0);
  });
});
