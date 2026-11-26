import {bundledCatalog} from '../catalog/bundledCatalog';
import {judgeCalibration, SpeedMeter} from '../policy/calibration';

/** Feed `tokensPerSecond` for `seconds`, one token at a time. */
function run(
  meter: SpeedMeter,
  clock: {t: number},
  rate: number,
  seconds: number,
) {
  const step = 1000 / rate;
  meter.onTokens();
  for (let elapsed = step; elapsed <= seconds * 1000 + 0.001; elapsed += step) {
    clock.t += step;
    meter.onTokens();
  }
}

describe('SpeedMeter', () => {
  it('measures tokens per second over the window', () => {
    const clock = {t: 1000};
    const meter = new SpeedMeter(5, () => clock.t);
    run(meter, clock, 20, 5);
    expect(meter.done).toBe(true);
    expect(meter.sample()?.tokensPerSecond).toBeCloseTo(20, 1);
    expect(meter.sample()?.seconds).toBeCloseTo(5, 1);
  });

  it('starts the clock at the first token, not at the request', () => {
    const clock = {t: 0};
    const meter = new SpeedMeter(5, () => clock.t);
    // Eight seconds of prompt processing before anything streams.
    clock.t = 8000;
    run(meter, clock, 30, 5);
    expect(meter.sample()?.tokensPerSecond).toBeCloseTo(30, 1);
  });

  it('counts batches of tokens', () => {
    const clock = {t: 0};
    const meter = new SpeedMeter(2, () => clock.t);
    meter.onTokens(1);
    for (let i = 0; i < 4; i++) {
      clock.t += 500;
      meter.onTokens(8);
    }
    expect(meter.sample()).toEqual({
      tokens: 32,
      seconds: 2,
      tokensPerSecond: 16,
    });
  });

  it('stops counting once the window is full', () => {
    const clock = {t: 0};
    const meter = new SpeedMeter(2, () => clock.t);
    run(meter, clock, 10, 2);
    const before = meter.sample();
    clock.t += 60000;
    meter.onTokens(500);
    expect(meter.sample()).toEqual(before);
  });

  it('does not count the time between answers', () => {
    const clock = {t: 0};
    const meter = new SpeedMeter(5, () => clock.t);
    run(meter, clock, 20, 3);
    meter.endSegment();
    // The user reads for a minute, then asks again.
    clock.t += 60_000;
    expect(meter.done).toBe(false);
    run(meter, clock, 20, 2);
    expect(meter.done).toBe(true);
    expect(meter.sample()?.seconds).toBeCloseTo(5, 1);
    expect(meter.sample()?.tokensPerSecond).toBeCloseTo(20, 0);
    meter.endSegment();
    meter.endSegment();
    expect(meter.sample()?.seconds).toBeCloseTo(5, 1);
  });

  it('treats a long silence as the end of an answer', () => {
    const clock = {t: 0};
    const meter = new SpeedMeter(5, () => clock.t);
    run(meter, clock, 20, 3);
    // Nobody reported the end of the answer.
    clock.t += 60_000;
    run(meter, clock, 20, 2);
    expect(meter.sample()?.tokensPerSecond).toBeCloseTo(20, 0);
  });

  it('has no opinion on too little data', () => {
    const clock = {t: 0};
    const meter = new SpeedMeter(5, () => clock.t);
    expect(meter.sample()).toBeNull();
    expect(meter.done).toBe(false);
    run(meter, clock, 10, 0.5);
    // Half a second, five tokens: a short answer, not a slow phone.
    expect(meter.sample()).toBeNull();
    clock.t += 1000;
    meter.onTokens(3);
    // Long enough now, but still under 16 tokens.
    expect(meter.sample()).toBeNull();
  });

  it('judges a very slow phone on a full window, however few the tokens', () => {
    const clock = {t: 0};
    const meter = new SpeedMeter(5, () => clock.t);
    // 2 tokens a second: 10 tokens in the window, fewer than the minimum for
    // a short answer, but five seconds of it is evidence enough.
    run(meter, clock, 2, 5);
    expect(meter.done).toBe(true);
    expect(meter.sample()?.tokensPerSecond).toBeCloseTo(2, 1);
    expect(
      judgeCalibration(meter.sample(), 'gemma-4-e2b-qat', bundledCatalog),
    ).toMatchObject({verdict: 'too_slow'});
  });

  it('defaults to the real clock', () => {
    const meter = new SpeedMeter(5);
    meter.onTokens();
    expect(meter.done).toBe(false);
  });
});

describe('calibration verdict', () => {
  const sample = (tokensPerSecond: number) => ({
    tokens: tokensPerSecond * 5,
    seconds: 5,
    tokensPerSecond,
  });

  it('is fine at or above the floor of 8 tokens a second', () => {
    expect(
      judgeCalibration(sample(8), 'gemma-4-e4b-qat', bundledCatalog),
    ).toEqual({verdict: 'ok', tokensPerSecond: 8});
  });

  it('offers the next smaller model below the floor', () => {
    expect(
      judgeCalibration(sample(5.5), 'gemma-4-e4b-qat', bundledCatalog),
    ).toEqual({
      verdict: 'too_slow',
      tokensPerSecond: 5.5,
      floor: 8,
      offerModelId: 'gemma-4-e2b-qat',
    });
  });

  it('offers only once', () => {
    const verdict = judgeCalibration(
      sample(5),
      'gemma-4-e4b-qat',
      bundledCatalog,
      {
        tokensPerSecond: 5,
        slowOfferShown: true,
      },
    );
    expect(verdict).toMatchObject({verdict: 'too_slow', offerModelId: null});
  });

  it('has nothing to offer below the smallest model', () => {
    expect(
      judgeCalibration(sample(3), 'lfm3-1.7b', bundledCatalog),
    ).toMatchObject({verdict: 'too_slow', offerModelId: null});
  });

  it('is inconclusive without a sample', () => {
    expect(judgeCalibration(null, 'lfm3-1.7b', bundledCatalog)).toEqual({
      verdict: 'inconclusive',
    });
  });
});
