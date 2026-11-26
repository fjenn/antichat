/** Dev entry: the voice UI check screen (see metro.voice-ui.config.js). */
import 'react-native-url-polyfill/auto';

import React from 'react';
import {AppRegistry, LogBox} from 'react-native';
import {GestureHandlerRootView} from 'react-native-gesture-handler';
import {SafeAreaProvider} from 'react-native-safe-area-context';

import {name as appName} from '../../../../../app.json';
import {VoiceDevScreen} from './VoiceDevScreen';

LogBox.ignoreAllLogs(true);
AppRegistry.registerComponent(appName, () => () => (
  <GestureHandlerRootView style={{flex: 1}}>
    <SafeAreaProvider>
      <VoiceDevScreen />
    </SafeAreaProvider>
  </GestureHandlerRootView>
));
