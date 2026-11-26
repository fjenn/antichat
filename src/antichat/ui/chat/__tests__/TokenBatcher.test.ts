import {TokenBatcher} from '../thread/TokenBatcher';
import {SCRIPTED_ANSWER, tokenize} from '../../../spike-ui/script';

describe('TokenBatcher', () => {
  const setup = (minIntervalMs = 0) => {
    const frames: Array<() => void> = [];
    const out: Array<[string, number]> = [];
    let now = 0;
    const batcher = new TokenBatcher((c, n) => out.push([c, n]), {
      schedule: cb => frames.push(cb),
      minIntervalMs,
      now: () => now,
    });
    const frame = (ms = 16) => {
      now += ms;
      frames.splice(0).forEach(cb => cb());
    };
    return {batcher, out, frame, frames};
  };

  it('delivers all tokens of a frame in one flush, in order', () => {
    const {batcher, out, frame, frames} = setup();
    batcher.push('Hel');
    batcher.push('lo');
    batcher.push(' world');
    expect(out).toEqual([]);
    expect(frames).toHaveLength(1);
    frame();
    expect(out).toEqual([['Hello world', 3]]);
    expect(batcher.stats).toEqual({tokens: 3, flushes: 1, maxBatch: 3});
  });

  it('does not schedule frames while idle', () => {
    const {batcher, frame, frames} = setup();
    batcher.push('a');
    frame();
    expect(frames).toHaveLength(0);
  });

  it('holds tokens back until the minimum interval has passed', () => {
    const {batcher, out, frame} = setup(40);
    batcher.push('a');
    frame();
    batcher.push('b');
    frame();
    expect(out).toEqual([['a', 1]]);
    batcher.push('c');
    frame();
    frame();
    expect(out).toEqual([
      ['a', 1],
      ['bc', 2],
    ]);
  });

  it('end() flushes at once and ignores later tokens', () => {
    const {batcher, out, frame} = setup(1000);
    batcher.push('a');
    frame();
    batcher.push('b');
    batcher.end();
    batcher.push('c');
    frame();
    expect(out.map(o => o[0]).join('')).toBe('ab');
  });
});

describe('tokenize', () => {
  it('loses no characters and yields model-sized tokens', () => {
    const tokens = tokenize(SCRIPTED_ANSWER);
    expect(tokens.join('')).toBe(SCRIPTED_ANSWER);
    const words = SCRIPTED_ANSWER.split(/\s+/).length;
    expect(words).toBeGreaterThan(550);
    expect(tokens.length / words).toBeGreaterThan(1.2);
    expect(Math.max(...tokens.map(t => t.trim().length))).toBeLessThanOrEqual(
      5,
    );
  });
});
