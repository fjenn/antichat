/**
 * Applies the user's appearance choice to Unistyles and to the native side.
 * Switching is live: Unistyles restyles native views without re-rendering
 * React.
 *
 * `Appearance.setColorScheme` is the root fix for native overlays: on iOS it
 * sets `overrideUserInterfaceStyle` on every window, so TrueSheet sheets,
 * blur glass, UIMenu/context menus, alerts, action sheets, pickers and the
 * keyboard inherit the app theme instead of the system one; on Android it
 * sets the AppCompat night mode, which PopupMenu, dialogs and pickers read.
 */
import {Appearance} from 'react-native';
import {UnistylesRuntime} from 'react-native-unistyles';

import {ACCENTS, type AccentName} from './accents';

export type ThemeMode = 'system' | 'light' | 'dark';

export function applyThemeMode(mode: ThemeMode): void {
  Appearance.setColorScheme(mode === 'system' ? 'unspecified' : mode);
  if (mode === 'system') {
    UnistylesRuntime.setAdaptiveThemes(true);
    return;
  }
  UnistylesRuntime.setAdaptiveThemes(false);
  UnistylesRuntime.setTheme(mode);
}

export function applyAccent(accent: AccentName): void {
  (['light', 'dark'] as const).forEach(scheme => {
    UnistylesRuntime.updateTheme(scheme, theme => ({
      ...theme,
      accentName: accent,
      colors: {...theme.colors, ...ACCENTS[accent][scheme]},
    }));
  });
}
