/**
 * The two colour schemes. Colours are semantic: components never name a hex
 * value, they name a role.
 */
import {
  ACCENTS,
  DEFAULT_ACCENT,
  type AccentColors,
  type AccentName,
  type SchemeName,
} from './accents';
import {blur, motion, radii, sizes, spacing, typography} from './tokens';

export interface BaseColors {
  /** The chat screen. */
  background: string;
  /** Sheets, menus, cards that sit above the background. */
  backgroundElevated: string;
  drawer: string;
  /** Quiet grey fill: fields, suggestion cards, selected rows. */
  surface: string;
  surfacePressed: string;
  textPrimary: string;
  textSecondary: string;
  textTertiary: string;
  /** Hairlines. */
  border: string;
  /** Dim layer behind the drawer and sheets. */
  scrim: string;
  danger: string;
  dangerSoft: string;
  success: string;
  warning: string;
  /** Off track of a toggle. */
  controlTrack: string;
  controlThumb: string;
  /** Fill of the glass fallback (no blur behind it). */
  glassSolid: string;
  /** Tint laid over real blur. */
  glassTint: string;
  glassBorder: string;
  skeleton: string;
  skeletonHighlight: string;
  /** Toast background: inverse of the screen. */
  inverse: string;
  onInverse: string;
}

export type ThemeColors = BaseColors & AccentColors;

const lightBase: BaseColors = {
  background: '#FFFFFF',
  backgroundElevated: '#FFFFFF',
  drawer: '#FFFFFF',
  surface: '#F4F4F4',
  surfacePressed: '#E9E9E9',
  textPrimary: '#0D0D0D',
  textSecondary: '#5D5D5D',
  textTertiary: '#8E8E8E',
  border: 'rgba(13, 13, 13, 0.10)',
  scrim: 'rgba(0, 0, 0, 0.32)',
  danger: '#DC2F2A',
  dangerSoft: '#FDECEB',
  success: '#10A64A',
  warning: '#B76E00',
  controlTrack: '#E3E3E3',
  controlThumb: '#FFFFFF',
  glassSolid: 'rgb(255, 255, 255)',
  glassTint: 'rgba(255, 255, 255, 0.55)',
  glassBorder: 'rgba(13, 13, 13, 0.08)',
  skeleton: '#EFEFEF',
  skeletonHighlight: '#FAFAFA',
  inverse: '#1F1F1F',
  onInverse: '#FFFFFF',
};

/** Dark is true black, as on OLED phones. */
const darkBase: BaseColors = {
  background: '#000000',
  backgroundElevated: '#1A1A1A',
  drawer: '#000000',
  surface: '#1F1F1F',
  surfacePressed: '#2C2C2C',
  textPrimary: '#FFFFFF',
  textSecondary: '#B4B4B4',
  textTertiary: '#7C7C7C',
  border: 'rgba(255, 255, 255, 0.14)',
  scrim: 'rgba(0, 0, 0, 0.56)',
  danger: '#FF6B66',
  dangerSoft: '#3A1513',
  success: '#2BBF63',
  warning: '#FFB84D',
  controlTrack: '#3A3A3A',
  controlThumb: '#FFFFFF',
  glassSolid: 'rgb(32, 32, 32)',
  glassTint: 'rgba(40, 40, 40, 0.55)',
  glassBorder: 'rgba(255, 255, 255, 0.12)',
  skeleton: '#1C1C1C',
  skeletonHighlight: '#2A2A2A',
  inverse: '#F4F4F4',
  onInverse: '#0D0D0D',
};

/** Shadows as CSS `boxShadow`, which draws the same on iOS and Android. */
const elevation = {
  light: {
    none: 'none',
    /** Glass buttons, the composer. */
    raised: '0px 2px 10px rgba(0, 0, 0, 0.08), 0px 0px 1px rgba(0, 0, 0, 0.10)',
    /** Menus, toasts. */
    floating:
      '0px 8px 28px rgba(0, 0, 0, 0.14), 0px 0px 1px rgba(0, 0, 0, 0.12)',
  },
  dark: {
    none: 'none',
    raised: '0px 2px 10px rgba(0, 0, 0, 0.5)',
    floating: '0px 8px 28px rgba(0, 0, 0, 0.6)',
  },
} as const;

export function buildTheme(scheme: SchemeName, accent: AccentName) {
  return {
    scheme,
    accentName: accent,
    dark: scheme === 'dark',
    colors: {
      ...(scheme === 'dark' ? darkBase : lightBase),
      ...ACCENTS[accent][scheme],
    } as ThemeColors,
    spacing,
    radii,
    sizes,
    typography,
    motion,
    blur,
    elevation: elevation[scheme] as Record<
      'none' | 'raised' | 'floating',
      string
    >,
  };
}

export type AppTheme = ReturnType<typeof buildTheme>;
export type ColorToken = keyof ThemeColors;

export const lightTheme = buildTheme('light', DEFAULT_ACCENT);
export const darkTheme = buildTheme('dark', DEFAULT_ACCENT);
