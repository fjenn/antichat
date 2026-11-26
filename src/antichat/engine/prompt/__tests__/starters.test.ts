import {STARTERS, daySeed, pickStarters} from '../starters';

describe('starters', () => {
  it('has unique ids, short labels and real prompts', () => {
    expect(new Set(STARTERS.map(s => s.id)).size).toBe(STARTERS.length);
    for (const starter of STARTERS) {
      expect(starter.label.length).toBeLessThanOrEqual(32);
      expect(starter.prompt.length).toBeGreaterThan(20);
    }
    expect(STARTERS.length).toBeGreaterThanOrEqual(20);
  });

  it('picks the same set for the same seed, from different categories', () => {
    const a = pickStarters(4, 20000);
    expect(pickStarters(4, 20000)).toEqual(a);
    expect(a).toHaveLength(4);
    expect(new Set(a.map(s => s.category)).size).toBe(4);
  });

  it('rotates: a month of days shows most of the list', () => {
    const seen = new Set<string>();
    for (let day = 0; day < 30; day++) {
      pickStarters(4, 20000 + day).forEach(s => seen.add(s.id));
    }
    expect(seen.size).toBeGreaterThan(STARTERS.length * 0.8);
  });

  it('fills up when more are asked for than there are categories', () => {
    const many = pickStarters(10, 7);
    expect(many).toHaveLength(10);
    expect(new Set(many.map(s => s.id)).size).toBe(10);
    expect(pickStarters(100, 7)).toHaveLength(STARTERS.length);
  });

  it('changes the default seed once a day', () => {
    const morning = new Date(2026, 10, 24, 8, 0);
    const evening = new Date(2026, 10, 24, 23, 30);
    const tomorrow = new Date(2026, 10, 25, 0, 30);
    expect(daySeed(morning)).toBe(daySeed(evening));
    expect(daySeed(tomorrow)).toBe(daySeed(morning) + 1);
  });
});
