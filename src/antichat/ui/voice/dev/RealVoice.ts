/**
 * The real voice engine for the check screen: PocketPal's Whisper and the
 * platform audio session and permission, with the microphone fed from the
 * engine harness's WAV fixtures. Input,
 * put on the device by `run-ui.sh`:
 *
 *   Documents/voice-harness/ui.json     {"session": "real" | "stub"}
 *   Documents/voice-harness/fixtures/   manifest.json + *.wav
 */
import {Platform} from 'react-native';

import * as RNFS from '@dr.pogodin/react-native-fs';
import {toByteArray} from 'base64-js';

import {getEngine} from '../../../../services/tts';
import {chunked, concatPcm, silence} from '../../../engine/voice/audio/pcm';
import {wavToSpeechPcm} from '../../../engine/voice/audio/wav';
import {createAudioSession} from '../../../engine/voice/bindings/audio';
import {
  createPlaybackKeeper,
  keepAwake,
  micPermission,
} from '../../../engine/voice/bindings/platform';
import {createSpeechTtsBackend} from '../../../engine/voice/bindings/speechTts';
import {createWhisperRnBackend} from '../../../engine/voice/bindings/whisperRn';
import {createScriptedChat} from '../../../engine/voice/harness/device/chat';
import type {
  AudioSessionPort,
  MicSource,
} from '../../../engine/voice/session/ports';
import {WhisperSttAdapter} from '../../../engine/voice/stt/whisperAdapter';
import type {TtsEngineId} from '../../../engine/voice/tts/voices';
import {VoiceEngine} from '../../../engine/voice/VoiceEngine';

export const HARNESS_DIR = `${RNFS.DocumentDirectoryPath}/voice-harness`;

const REPLY =
  'Paris is the capital of France. About two million people live in the city itself, and more than ten million in the wider region. It has been the capital for over a thousand years, and the river Seine runs through the middle of it. ';

export interface RealVoiceConfig {
  session?: 'real' | 'stub';
}

export interface RealVoice {
  port: VoiceEngine;
  /** Plays a fixture into the microphone. */
  say(id: string): void;
  /** Words of a fixture, to compare with what was heard. */
  text(id: string): string;
  dispose(): void;
}

const sleep = (ms: number) =>
  new Promise<void>(resolve => setTimeout(resolve, ms));

const STUB_SESSION: AudioSessionPort = {
  activate: async () => ({route: 'speaker', echoCancellation: true}),
  deactivate: async () => {},
  setOutput: async () => ({route: 'speaker', echoCancellation: true}),
  on: () => () => {},
};

export async function readConfig(): Promise<RealVoiceConfig | null> {
  try {
    return JSON.parse(await RNFS.readFile(`${HARNESS_DIR}/ui.json`, 'utf8'));
  } catch {
    return null;
  }
}

export async function createRealVoice(
  config: RealVoiceConfig,
): Promise<RealVoice> {
  const fixtures: {id: string; file: string; text: string}[] = JSON.parse(
    await RNFS.readFile(`${HARNESS_DIR}/fixtures/manifest.json`, 'utf8'),
  );
  const pcm = new Map<string, Int16Array>();
  const load = async (id: string) => {
    const fixture = fixtures.find(f => f.id === id)!;
    const base64 = await RNFS.readFile(
      `${HARNESS_DIR}/fixtures/${fixture.file}`,
      'base64',
    );
    pcm.set(id, wavToSpeechPcm(toByteArray(base64)));
  };
  await Promise.all(['en-us-capital', 'de-de-wetter'].map(load));

  // The microphone: 50 ms chunks in real time, silence between fixtures.
  let queue: Int16Array[] = [];
  let pumping = 0;
  const mic: MicSource = {
    async start(onChunk) {
      const run = ++pumping;
      (async () => {
        let next = Date.now();
        while (run === pumping) {
          onChunk(queue.shift() ?? silence(50));
          next += 50;
          await sleep(Math.max(0, next - Date.now()));
        }
      })();
    },
    async stop() {
      pumping++;
      queue = [];
    },
  };

  const neural: Exclude<TtsEngineId, 'system'>[] = [
    'kitten',
    'kokoro',
    'phonon',
    'supertonic',
  ];
  const present = await Promise.all(
    neural.map(id =>
      getEngine(id)
        .isInstalled()
        .catch(() => false),
    ),
  );
  const installed = neural.filter((_, index) => present[index]);

  const port = new VoiceEngine({
    stt: new WhisperSttAdapter(createWhisperRnBackend(() => 'base')),
    tts: createSpeechTtsBackend(),
    session: config.session === 'stub' ? STUB_SESSION : createAudioSession(),
    mic,
    chat: createScriptedChat(REPLY + REPLY),
    keepAwake,
    permission: micPermission,
    keeper: createPlaybackKeeper({
      title: 'AntiChat',
      stopLabel: 'Stop',
      channelName: 'Read aloud',
    }),
    facts: () => ({
      deviceClass: 'C',
      platform: Platform.OS === 'ios' ? 'ios' : 'android',
      phononSupported: false,
      installedEngines: installed,
      language: 'en',
    }),
    initial: {settings: {language: 'auto'}},
  });

  return {
    port,
    say(id) {
      const padded = concatPcm([pcm.get(id)!, silence(40)]);
      queue = [...chunked(padded, 50)].map(chunk => {
        const full = new Int16Array(800);
        full.set(chunk);
        return full;
      });
    },
    text: id => fixtures.find(f => f.id === id)?.text ?? '',
    dispose() {
      pumping++;
      port.stopVoiceMode();
      port.stopSpeech();
      port.cancelDictation();
    },
  };
}
