/**
 * Design tokens that do not depend on the colour scheme: spacing, radii,
 * type scale, motion. One 4-point grid on both platforms.
 */
import type {TextStyle} from 'react-native';

export const spacing = {
  none: 0,
  xxs: 2,
  xs: 4,
  sm: 8,
  md: 12,
  lg: 16,
  xl: 20,
  xxl: 24,
  xxxl: 32,
  huge: 48,
} as const;

export const radii = {
  xs: 6,
  sm: 10,
  md: 14,
  lg: 18,
  /** The user bubble and suggestion cards. */
  xl: 22,
  /** Sheets. */
  sheet: 28,
  pill: 999,
} as const;

/** Sizes of things you tap. 44 is the smallest target on both platforms. */
export const sizes = {
  hitTarget: 44,
  iconSm: 18,
  icon: 22,
  iconLg: 26,
  topBarButton: 44,
  composerMinHeight: 52,
  row: 48,
  hairline: 0.5,
} as const;

export type TextVariant =
  | 'largeTitle'
  | 'title'
  | 'headline'
  | 'body'
  | 'bodyStrong'
  | 'callout'
  | 'calloutStrong'
  | 'footnote'
  | 'caption'
  | 'button';

export interface TypeStyle {
  fontSize: number;
  lineHeight: number;
  fontWeight: NonNullable<TextStyle['fontWeight']>;
  letterSpacing: number;
  /**
   * Cap on Dynamic Type / Android font scale for this style. Reading text
   * follows the system all the way; chrome grows less so bars keep working.
   */
  maxFontSizeMultiplier: number;
}

export const typography: Record<TextVariant, TypeStyle> = {
  largeTitle: {
    fontSize: 28,
    lineHeight: 34,
    fontWeight: '600',
    letterSpacing: -0.5,
    maxFontSizeMultiplier: 1.5,
  },
  title: {
    fontSize: 22,
    lineHeight: 28,
    fontWeight: '600',
    letterSpacing: -0.4,
    maxFontSizeMultiplier: 1.6,
  },
  headline: {
    fontSize: 17,
    lineHeight: 22,
    fontWeight: '600',
    letterSpacing: -0.3,
    maxFontSizeMultiplier: 1.6,
  },
  body: {
    fontSize: 16,
    lineHeight: 24,
    fontWeight: '400',
    letterSpacing: -0.2,
    maxFontSizeMultiplier: 2.4,
  },
  bodyStrong: {
    fontSize: 16,
    lineHeight: 24,
    fontWeight: '600',
    letterSpacing: -0.2,
    maxFontSizeMultiplier: 2.4,
  },
  callout: {
    fontSize: 15,
    lineHeight: 20,
    fontWeight: '400',
    letterSpacing: -0.15,
    maxFontSizeMultiplier: 2,
  },
  calloutStrong: {
    fontSize: 15,
    lineHeight: 20,
    fontWeight: '600',
    letterSpacing: -0.15,
    maxFontSizeMultiplier: 2,
  },
  footnote: {
    fontSize: 13,
    lineHeight: 18,
    fontWeight: '400',
    letterSpacing: -0.05,
    maxFontSizeMultiplier: 2,
  },
  caption: {
    fontSize: 12,
    lineHeight: 16,
    fontWeight: '500',
    letterSpacing: 0,
    maxFontSizeMultiplier: 1.8,
  },
  button: {
    fontSize: 16,
    lineHeight: 22,
    fontWeight: '600',
    letterSpacing: -0.2,
    maxFontSizeMultiplier: 1.6,
  },
};

/** Milliseconds. Reduce Motion collapses all of them to `instant`. */
export const motion = {
  duration: {
    instant: 0,
    fast: 120,
    base: 200,
    slow: 320,
    /** One shimmer sweep. */
    shimmer: 1400,
  },
  /** Reanimated `withSpring` configs. */
  spring: {
    /** Press feedback, toggles. */
    snappy: {damping: 22, stiffness: 320, mass: 0.8},
    /** Drawer, sheets, things that travel. */
    gentle: {damping: 26, stiffness: 220, mass: 1},
  },
  /** Cubic bezier control points for timing animations. */
  easing: {
    standard: [0.2, 0, 0, 1],
    exit: [0.4, 0, 1, 1],
  },
  /** Press feedback. */
  pressScale: 0.96,
  pressOpacity: 0.7,
} as const;

export const blur = {
  /** Blur radius of the glass fallback. */
  glass: 24,
  /** Opacity of the solid fill used where blur is unavailable. */
  solidFallbackAlpha: 0.94,
} as const;
