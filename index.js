/**
 * @format
 */

// Hermes/React Native ship no URL; it must exist before the app graph loads.
import 'react-native-url-polyfill/auto';

import {AppRegistry, LogBox} from 'react-native';

// Silence LogBox in E2E builds so the in-app warning toast doesn't cover
// chat-bottom controls Appium needs. Left active otherwise so warnings
// surface during development.
if (__E2E__) {
  LogBox.ignoreAllLogs(true);
}

import {name as appName} from './app.json';
// ANTICHAT: the root is chosen in src/antichat (spike harness or the app).
import {antichatRoot} from './src/antichat';

AppRegistry.registerComponent(appName, () =>
  antichatRoot(() => require('./App').default),
);
