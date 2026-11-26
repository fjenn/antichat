/**
 * Audio session, microphone and file decoding through react-native-audio-api.
 *
 * Echo cancellation is the platform's: the recorder runs through Apple's
 * voice-processing I/O (`iosVoiceProcessing`) and Android's
 * `voiceCommunication` capture preset, with the session in voice-chat mode.
 */
import {Platform} from 'react-native';

import {
  AudioManager,
  AudioRecorder,
  decodeAudioData,
} from 'react-native-audio-api';

import {floatToPcm} from '../audio/pcm';
import type {WavAudio} from '../audio/wav';
import type {
  AudioRoute,
  AudioSessionPort,
  MicSource,
  SessionEvent,
  SessionInfo,
  SessionProfile,
} from '../session/ports';
import {routeFromPort} from '../session/route';
import type {AudioFileDecoder} from '../stt/fileTranscriber';
import {SAMPLE_RATE} from '../types';

export function createAudioSession(): AudioSessionPort {
  const listeners = new Set<(event: SessionEvent) => void>();
  let profile: SessionProfile | null = null;
  let subscriptions: ({remove(): void} | undefined)[] = [];

  const currentRoute = async (): Promise<AudioRoute> => {
    try {
      if (Platform.OS === 'android') {
        const device = await AudioManager.getCommunicationDevice();
        return device ? routeFromPort(device.category) : 'speaker';
      }
      const info = await AudioManager.getDevicesInfo();
      return routeFromPort(info.currentOutputs[0]?.category);
    } catch {
      return 'unknown';
    }
  };
  const info = async (): Promise<SessionInfo> => ({
    route: await currentRoute(),
    // The recorder is created with the platform's voice processing whenever
    // the session is a conversation.
    echoCancellation: profile === 'conversation',
  });
  const emit = (event: SessionEvent) => listeners.forEach(l => l(event));

  const configure = (next: SessionProfile) => {
    if (next === 'conversation') {
      AudioManager.setSystemOptions({
        ios: {
          category: 'playAndRecord',
          mode: 'voiceChat',
          options: [
            'defaultToSpeaker',
            'allowBluetoothHFP',
            'allowBluetoothA2DP',
          ],
        },
        android: {mode: 'inCommunication', communicationDevice: 'speaker'},
      });
    } else if (next === 'dictation') {
      AudioManager.setSystemOptions({
        ios: {
          category: 'playAndRecord',
          mode: 'measurement',
          options: ['allowBluetoothHFP', 'duckOthers'],
          notifyOthersOnDeactivation: true,
        },
      });
    } else {
      // Read-aloud: a playback session keeps going with the screen locked
      // (UIBackgroundModes audio) and through the silent switch.
      AudioManager.setSystemOptions({
        ios: {
          category: 'playback',
          mode: 'spokenAudio',
          options: ['allowBluetoothA2DP', 'allowAirPlay'],
          notifyOthersOnDeactivation: true,
        },
      });
    }
  };

  return {
    async activate(next) {
      profile = next;
      configure(next);
      await AudioManager.setAudioSessionActivity(true);
      if (subscriptions.length === 0) {
        AudioManager.observeAudioInterruptions(true);
        subscriptions = [
          AudioManager.addSystemEventListener('interruption', event =>
            emit(
              event.type === 'began'
                ? {type: 'interruption_began'}
                : {
                    type: 'interruption_ended',
                    shouldResume: event.shouldResume,
                  },
            ),
          ),
          AudioManager.addSystemEventListener('routeChange', async event =>
            emit({
              type: 'route_changed',
              route: await currentRoute(),
              reason:
                event.reason === 'NewDeviceAvailable'
                  ? 'new_device'
                  : event.reason === 'OldDeviceUnavailable'
                    ? 'device_removed'
                    : 'other',
            }),
          ),
        ];
      }
      return info();
    },

    async deactivate() {
      profile = null;
      subscriptions.forEach(subscription => subscription?.remove());
      subscriptions = [];
      AudioManager.observeAudioInterruptions(false);
      await AudioManager.setAudioSessionActivity(false);
    },

    async setOutput(output) {
      if (Platform.OS === 'android') {
        await AudioManager.setCommunicationDevice(
          output === 'auto' ? 'systemDefault' : output,
        );
      } else if (profile === 'conversation') {
        AudioManager.setSystemOptions({
          ios: {
            category: 'playAndRecord',
            mode: 'voiceChat',
            // Without defaultToSpeaker a play-and-record session uses the
            // earpiece; a connected headset wins either way.
            options: [
              ...(output === 'earpiece' ? [] : (['defaultToSpeaker'] as const)),
              'allowBluetoothHFP',
              'allowBluetoothA2DP',
            ],
          },
        });
      }
      return info();
    },

    on(listener) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
  };
}

export function createMicSource(): MicSource {
  let recorder: AudioRecorder | null = null;
  return {
    async start(onChunk, options) {
      recorder = new AudioRecorder({
        iosVoiceProcessing: options.echoCancellation,
        androidInputPreset: options.echoCancellation
          ? 'voiceCommunication'
          : 'voiceRecognition',
      });
      recorder.onAudioReady(
        {
          sampleRate: SAMPLE_RATE,
          bufferLength: SAMPLE_RATE / 20,
          channelCount: 1,
        },
        event => onChunk(floatToPcm(event.buffer.getChannelData(0))),
      );
      recorder.onError(error =>
        console.warn('[voice] recorder:', error.message),
      );
      const result = await recorder.start();
      if (result.status === 'error') {
        recorder = null;
        throw new Error(result.message);
      }
    },
    async stop() {
      const current = recorder;
      recorder = null;
      if (current) {
        current.clearOnAudioReady();
        current.clearOnError();
        await current.stop();
      }
    },
  };
}

/** Decodes an audio attachment (m4a, mp3, wav, …) straight to 16 kHz. */
export function createAudioFileDecoder(): AudioFileDecoder {
  return {
    async decode(uri: string): Promise<WavAudio> {
      const buffer = await decodeAudioData(uri, SAMPLE_RATE);
      return {
        sampleRate: buffer.sampleRate,
        channels: buffer.numberOfChannels,
        data: Array.from({length: buffer.numberOfChannels}, (_, channel) =>
          buffer.getChannelData(channel),
        ),
      };
    },
  };
}
