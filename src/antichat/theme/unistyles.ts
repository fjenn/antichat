/**
 * Registers the themes with Unistyles. Must run before any stylesheet is
 * created, so `src/antichat/app` imports it first.
 */
import {StyleSheet} from 'react-native-unistyles';

import {darkTheme, lightTheme, type AppTheme} from './themes';

declare module 'react-native-unistyles' {
  export interface UnistylesThemes {
    light: AppTheme;
    dark: AppTheme;
  }
}

StyleSheet.configure({
  themes: {light: lightTheme, dark: darkTheme},
  settings: {adaptiveThemes: true},
});
