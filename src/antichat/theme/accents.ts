/**
 * Accent colours. The accent tints the user bubble, the voice button, toggles
 * and highlights. `neutral` is the black/white option.
 */
export type AccentName =
  | 'blue'
  | 'green'
  | 'yellow'
  | 'pink'
  | 'orange'
  | 'purple'
  | 'neutral';

export type SchemeName = 'light' | 'dark';

export interface AccentColors {
  /** Solid fill: voice button, toggle track, primary highlights. */
  accent: string;
  /** Text or icon on top of `accent`. */
  onAccent: string;
  /** Soft fill: the user bubble, selected chips. */
  accentSoft: string;
  /** Text on top of `accentSoft`. */
  onAccentSoft: string;
}

export const ACCENT_NAMES: readonly AccentName[] = [
  'blue',
  'green',
  'yellow',
  'pink',
  'orange',
  'purple',
  'neutral',
];

export const DEFAULT_ACCENT: AccentName = 'blue';

const INK = '#0D0D0D';
const PAPER = '#FFFFFF';

export const ACCENTS: Record<AccentName, Record<SchemeName, AccentColors>> = {
  blue: {
    light: {
      accent: '#0A84FF',
      onAccent: PAPER,
      accentSoft: '#E4F1FF',
      onAccentSoft: '#0B62C4',
    },
    dark: {
      accent: '#2B95FF',
      onAccent: PAPER,
      accentSoft: '#0A3D75',
      onAccentSoft: '#D6EAFF',
    },
  },
  green: {
    light: {
      accent: '#10A64A',
      onAccent: PAPER,
      accentSoft: '#DDF5E6',
      onAccentSoft: '#0B7534',
    },
    dark: {
      accent: '#2BBF63',
      onAccent: INK,
      accentSoft: '#0C4F26',
      onAccentSoft: '#CDF5DC',
    },
  },
  yellow: {
    light: {
      accent: '#F5B800',
      onAccent: INK,
      accentSoft: '#FFF4CF',
      onAccentSoft: '#7A5B00',
    },
    dark: {
      accent: '#FFC933',
      onAccent: INK,
      accentSoft: '#4F3C00',
      onAccentSoft: '#FFEBAD',
    },
  },
  pink: {
    light: {
      accent: '#F0479A',
      onAccent: PAPER,
      accentSoft: '#FFE6F2',
      onAccentSoft: '#B81468',
    },
    dark: {
      accent: '#FF6FB3',
      onAccent: INK,
      accentSoft: '#6E103F',
      onAccentSoft: '#FFD6E9',
    },
  },
  orange: {
    light: {
      accent: '#F26B1D',
      onAccent: PAPER,
      accentSoft: '#FFE9DB',
      onAccentSoft: '#AD440A',
    },
    dark: {
      accent: '#FF8A47',
      onAccent: INK,
      accentSoft: '#6B2A05',
      onAccentSoft: '#FFDCC7',
    },
  },
  purple: {
    light: {
      accent: '#8B4DF0',
      onAccent: PAPER,
      accentSoft: '#EFE6FE',
      onAccentSoft: '#6229C2',
    },
    dark: {
      accent: '#A677FF',
      onAccent: INK,
      accentSoft: '#3F1D85',
      onAccentSoft: '#E5D6FF',
    },
  },
  neutral: {
    light: {
      accent: INK,
      onAccent: PAPER,
      accentSoft: '#F1F1F1',
      onAccentSoft: INK,
    },
    dark: {
      accent: PAPER,
      onAccent: INK,
      accentSoft: '#2A2A2A',
      onAccentSoft: PAPER,
    },
  },
};
