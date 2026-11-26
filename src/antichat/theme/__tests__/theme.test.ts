/* eslint-disable no-bitwise */
import {ACCENTS, ACCENT_NAMES} from '../accents';
import {buildTheme} from '../themes';
import {typography} from '../tokens';

function channel(value: number): number {
  const c = value / 255;
  return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
}

function luminance(hex: string): number {
  const n = parseInt(hex.slice(1), 16);
  return (
    0.2126 * channel((n >> 16) & 255) +
    0.7152 * channel((n >> 8) & 255) +
    0.0722 * channel(n & 255)
  );
}

function contrast(a: string, b: string): number {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

describe('theme', () => {
  it.each(['light', 'dark'] as const)('%s text is readable', scheme => {
    const {colors} = buildTheme(scheme, 'blue');
    expect(contrast(colors.textPrimary, colors.background)).toBeGreaterThan(7);
    expect(contrast(colors.textSecondary, colors.background)).toBeGreaterThan(
      4.5,
    );
    expect(contrast(colors.textPrimary, colors.surface)).toBeGreaterThan(7);
    expect(contrast(colors.danger, colors.background)).toBeGreaterThan(4.5);
    expect(contrast(colors.onInverse, colors.inverse)).toBeGreaterThan(7);
  });

  it('keeps bubble text readable in every accent', () => {
    for (const accent of ACCENT_NAMES) {
      for (const scheme of ['light', 'dark'] as const) {
        const colors = ACCENTS[accent][scheme];
        expect(
          contrast(colors.onAccentSoft, colors.accentSoft),
        ).toBeGreaterThan(4.5);
        expect(contrast(colors.onAccent, colors.accent)).toBeGreaterThan(2.9);
      }
    }
  });

  it('is true black in dark and takes the accent', () => {
    const theme = buildTheme('dark', 'green');
    expect(theme.colors.background).toBe('#000000');
    expect(theme.colors.accent).toBe(ACCENTS.green.dark.accent);
    expect(theme.dark).toBe(true);
  });

  it('gives every text style room for its line and a font-scale cap', () => {
    for (const style of Object.values(typography)) {
      expect(style.lineHeight).toBeGreaterThanOrEqual(style.fontSize * 1.2);
      expect(style.maxFontSizeMultiplier).toBeGreaterThanOrEqual(1.5);
    }
  });
});
