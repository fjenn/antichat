/**
 * Entry point of the voice device harness. Metro serves it in place of
 * `index.js` (see metro.harness.config.js), so the installed debug app runs
 * the harness instead of the app, without any change to shared files.
 */
import 'react-native-url-polyfill/auto';

import {AppRegistry, LogBox} from 'react-native';

import {name as appName} from '../../../../../../app.json';
import {DeviceHarness} from './DeviceHarness';

LogBox.ignoreAllLogs(true);
AppRegistry.registerComponent(appName, () => DeviceHarness);
