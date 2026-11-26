import {
  durationParts,
  formatBytes,
  formatPercent,
  formatProgressBytes,
} from '../format';

describe('formatBytes', () => {
  it('uses decimal units and one decimal under 10 GB', () => {
    expect(formatBytes(5_210_000_000)).toBe('5.2 GB');
    expect(formatBytes(1_000_000_000)).toBe('1 GB');
    expect(formatBytes(12_400_000_000)).toBe('12 GB');
    expect(formatBytes(840_000_000)).toBe('840 MB');
    expect(formatBytes(12_000)).toBe('12 KB');
    expect(formatBytes(0)).toBe('0 B');
  });

  it('survives nonsense', () => {
    expect(formatBytes(-5)).toBe('0 B');
    expect(formatBytes(Number.NaN)).toBe('0 B');
  });

  it('says the unit once when both sides share it', () => {
    expect(formatProgressBytes(1_300_000_000, 5_200_000_000)).toBe(
      '1.3 of 5.2 GB',
    );
    expect(formatProgressBytes(300_000_000, 5_200_000_000)).toBe(
      '300 MB of 5.2 GB',
    );
  });
});

describe('durationParts', () => {
  it('does not count down the last seconds', () => {
    expect(durationParts(4)).toEqual({unit: 'moment'});
  });

  it('rounds seconds to tens so the line stays calm', () => {
    expect(durationParts(34)).toEqual({unit: 'seconds', value: 30});
    expect(durationParts(48)).toEqual({unit: 'seconds', value: 50});
  });

  it('uses minutes and hours', () => {
    expect(durationParts(58)).toEqual({unit: 'minutes', value: 1});
    expect(durationParts(230)).toEqual({unit: 'minutes', value: 4});
    expect(durationParts(2 * 3600)).toEqual({unit: 'hours', value: 2});
  });

  it('has nothing to say without an estimate', () => {
    expect(durationParts(undefined)).toBeNull();
    expect(durationParts(Number.POSITIVE_INFINITY)).toBeNull();
  });
});

describe('formatPercent', () => {
  it('never shows 100% before the end', () => {
    expect(formatPercent(0.999)).toBe('99%');
    expect(formatPercent(1)).toBe('100%');
    expect(formatPercent(0.344)).toBe('34%');
    expect(formatPercent(-1)).toBe('0%');
  });
});
