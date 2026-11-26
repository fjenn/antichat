/** Small platform services, each reused from PocketPal as it is. */
import {Platform} from 'react-native';

import {
  holdSpeechService,
  releaseSpeechService,
} from '../../../../services/tts/speechService';
import {ensureMicPermission} from '../../../../utils/asrMicPermission';
import {acquireKeepAwake} from '../../../../utils/keepAwake';
import type {KeepAwake, MicPermission} from '../session/ports';
import type {PlaybackKeeper} from '../tts/readAloud';

export const keepAwake: KeepAwake = {acquire: acquireKeepAwake};

export const micPermission: MicPermission = {ensure: ensureMicPermission};

/**
 * Keeps read-aloud alive with the screen locked. iOS needs nothing beyond
 * the playback audio session (the app has the audio background mode);
 * Android holds PocketPal's foreground speech service, whose notification
 * carries the stop action.
 */
export function createPlaybackKeeper(copy: {
  title: string;
  stopLabel: string;
  channelName: string;
}): PlaybackKeeper {
  let held = false;
  return {
    async hold(info) {
      if (Platform.OS === 'android' && !held) {
        held = true;
        await holdSpeechService({...copy, title: info.title || copy.title});
      }
    },
    release() {
      if (held) {
        held = false;
        releaseSpeechService();
      }
    },
  };
}
