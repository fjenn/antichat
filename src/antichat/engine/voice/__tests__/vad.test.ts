import {chunked, concatPcm, durationMs, mixPcm, silence} from '../audio/pcm';
import {fixturePcm, fixtures} from '../harness/fixtures';
import {EnergyVad} from '../vad/energyVad';
import {TurnDetector, type TurnEvent} from '../vad/turnDetector';

function run(
  pcm: Int16Array,
  detector = new TurnDetector({provisionalMs: 300}),
) {
  const events: TurnEvent[] = [];
  for (const chunk of chunked(pcm, 50)) {
    events.push(...detector.push(chunk));
  }
  return {events, detector};
}

const padded = (id: string, tailMs = 1200) =>
  concatPcm([silence(400), fixturePcm(id), silence(tailMs)]);

describe('TurnDetector on recorded speech', () => {
  const utterances = fixtures().filter(f => f.kind === 'utterance');

  it.each(utterances.map(f => [f.id]))(
    '%s: one turn, ended by the pause',
    id => {
      const pcm = padded(id);
      const {events} = run(pcm);
      const starts = events.filter(e => e.type === 'speech_start');
      const ends = events.filter(e => e.type === 'endpoint');
      expect(starts).toHaveLength(1);
      expect(ends).toHaveLength(1);
      const end = ends[0]!;
      if (end.type !== 'endpoint') {
        throw new Error('unreachable');
      }
      // The endpoint comes one hang time after the last word, not later.
      const speechEnd = 400 + durationMs(fixturePcm(id).length);
      expect(end.speechEndMs).toBeGreaterThan(speechEnd - 700);
      expect(end.speechEndMs).toBeLessThanOrEqual(speechEnd + 60);
      expect(end.atMs - end.speechEndMs).toBeGreaterThanOrEqual(700);
      expect(end.atMs - end.speechEndMs).toBeLessThan(760);
      expect(end.reason).toBe('pause');
    },
  );

  it('keeps the whole utterance, with pre-roll, for the recogniser', () => {
    const detector = new TurnDetector();
    const pcm = padded('en-gb-timer');
    let taken: Int16Array | null = null;
    for (const chunk of chunked(pcm, 50)) {
      if (detector.push(chunk).some(e => e.type === 'endpoint')) {
        taken = detector.take();
      }
    }
    const speech = fixturePcm('en-gb-timer').length;
    expect(taken!.length).toBeGreaterThanOrEqual(speech + 16 * 700);
    expect(taken!.length).toBeLessThan(speech + 16 * 1500);
  });

  it('hears nothing in room noise or silence', () => {
    expect(
      run(concatPcm([fixturePcm('room-noise'), fixturePcm('room-noise')]))
        .events,
    ).toEqual([]);
    expect(run(silence(5000)).events).toEqual([]);
  });

  it('ignores a click shorter than the minimum speech time', () => {
    const click = fixturePcm('en-us-capital').slice(8000, 8000 + 16 * 100);
    const {events} = run(concatPcm([silence(500), click, silence(1500)]));
    expect(events).toEqual([]);
  });

  it('fires provisional at the short pause and resumes when speech goes on', () => {
    const a = fixturePcm('en-us-bargein');
    const pcm = concatPcm([silence(300), a, silence(450), a, silence(1000)]);
    const types = run(pcm).events.map(e => e.type);
    expect(types[0]).toBe('speech_start');
    expect(types.filter(t => t === 'endpoint')).toHaveLength(1);
    const between = types.slice(types.indexOf('provisional'));
    expect(between).toContain('speech_resumed');
    expect(types[types.length - 1]).toBe('endpoint');
    expect(types[types.length - 2]).toBe('provisional');
  });

  it('ends an endless turn at the cap', () => {
    const detector = new TurnDetector({maxTurnMs: 3000});
    const {events} = run(fixturePcm('en-us-long'), detector);
    const first = events.find(e => e.type === 'endpoint');
    expect(first && first.type === 'endpoint' && first.reason).toBe('max');
  });

  it('long dictation: pauses of a second split it into turns', () => {
    const {events} = run(concatPcm([fixturePcm('en-us-long'), silence(1000)]));
    expect(
      events.filter(e => e.type === 'endpoint').length,
    ).toBeGreaterThanOrEqual(5);
  });
});

describe('EnergyVad', () => {
  it('adapts its floor to steady noise and still finds speech above it', () => {
    const vad = new EnergyVad();
    const noisy = fixturePcm('en-us-capital-snr15');
    const lead = fixturePcm('room-noise');
    let speechInNoise = 0;
    for (const frame of chunked(lead, 20)) {
      speechInNoise += vad.process(frame).speech ? 1 : 0;
    }
    expect(speechInNoise).toBe(0);
    let speech = 0;
    for (const frame of chunked(noisy, 20)) {
      if (frame.length === vad.frameSamples) {
        speech += vad.process(frame).speech ? 1 : 0;
      }
    }
    expect(speech).toBeGreaterThan(40);
  });

  it('a gate above the signal mutes it', () => {
    const vad = new EnergyVad();
    vad.setGateDb(0);
    const hits = [...chunked(fixturePcm('en-us-capital'), 20)].filter(
      f => f.length === vad.frameSamples && vad.process(f).speech,
    );
    expect(hits).toHaveLength(0);
  });

  it('speech over noise at 5 dB is still one turn', () => {
    const pcm = mixPcm(
      padded('en-us-capital-snr5'),
      fixturePcm('room-noise'),
      1,
    );
    const {events} = run(pcm);
    expect(events.filter(e => e.type === 'endpoint')).toHaveLength(1);
  });
});
