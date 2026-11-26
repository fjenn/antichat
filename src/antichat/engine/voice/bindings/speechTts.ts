/**
 * The voices of `@pocketpalai/react-native-speech` (system, Kitten, Kokoro,
 * Phonon, Supertonic) as a `TtsBackend`, through PocketPal's engine registry
 * and its runtime guard, so engine loading and swapping stay in one place.
 *
 * Units are appended to the library's speech stream, which synthesises ahead
 * of playback (no gap between sentences). Its progress events carry character
 * ranges of the stream text; they are mapped back to unit ids here.
 */
import Speech from '@pocketpalai/react-native-speech';
import type {StreamProgressEvent} from '@pocketpalai/react-native-speech';

import {getEngine, ttsRuntime} from '../../../../services/tts';
import {createEngineStreamingHandle} from '../../../../services/tts/streamingHandle';
import type {StreamingHandle} from '../../../../services/tts/types';
import type {
  TtsBackend,
  TtsStream,
  TtsStreamCallbacks,
  TtsStreamOptions,
} from '../tts/types';
import {UnitTracker} from '../tts/unitTracker';
import type {CatalogVoice} from '../tts/voices';
import {voiceError} from '../types';

const base = (tag?: string) => (tag ?? '').toLowerCase().split(/[-_]/)[0]!;

/** The phone's best voice for a language; undefined lets the OS choose. */
export async function systemVoiceFor(
  language: string | undefined,
): Promise<string | undefined> {
  if (!language) {
    return undefined;
  }
  try {
    const voices = await Speech.getAvailableVoices(language);
    const usable = voices.filter(
      voice =>
        !voice.networkConnectionRequired &&
        base(voice.language) === base(language),
    );
    const exact = usable.filter(
      voice => voice.language.toLowerCase() === language.toLowerCase(),
    );
    const pool = exact.length ? exact : usable;
    const best =
      pool.find(voice => String(voice.quality).toLowerCase() !== 'default') ??
      pool[0];
    return best?.identifier;
  } catch {
    return undefined;
  }
}

export function createSpeechTtsBackend(): TtsBackend {
  return {
    async prepare(voice: CatalogVoice): Promise<void> {
      const engine = getEngine(voice.engine);
      if (!(await engine.isInstalled())) {
        throw new Error(`voice engine ${voice.engine} is not installed`);
      }
      await ttsRuntime.acquire(engine, async () => {});
    },

    release: () => ttsRuntime.release(),

    open(options: TtsStreamOptions, callbacks: TtsStreamCallbacks): TtsStream {
      const engine = getEngine(options.voice.engine);
      const tracker = new UnitTracker(callbacks);
      const pending: string[] = [];
      let handle: StreamingHandle | null = null;
      let stopped = false;
      let failed = false;

      const fail = (err: unknown) => {
        if (!stopped && !failed) {
          failed = true;
          callbacks.onError(voiceError('failed', err));
        }
      };
      const opening = (async () => {
        const voiceId =
          options.voice.engine === 'system'
            ? ((await systemVoiceFor(options.language)) ?? '')
            : options.voice.engineVoiceId;
        if (stopped) {
          return;
        }
        handle = createEngineStreamingHandle(engine, voiceId, {
          speed: options.rate,
          language: options.language,
          onProgress: (event: StreamProgressEvent) => {
            if (!stopped) {
              tracker.progress(event.streamRange.start, event.streamRange.end);
            }
          },
        });
        pending.forEach(piece => handle!.appendText(piece));
        pending.length = 0;
      })().catch(fail);

      return {
        enqueue(id, text) {
          if (stopped) {
            return;
          }
          const piece = tracker.add(id, text);
          if (handle) {
            handle.appendText(piece);
          } else {
            pending.push(piece);
          }
        },
        async end() {
          await opening;
          try {
            await handle?.finalize();
            if (!stopped && !failed) {
              tracker.drain();
            }
          } catch (err) {
            fail(err);
          }
        },
        async stop() {
          if (stopped) {
            return;
          }
          stopped = true;
          pending.length = 0;
          // The native stop silences the speaker; the handle then drops what
          // is still queued for synthesis.
          // (Either call may return nothing instead of a promise.)
          await Promise.all([
            Promise.resolve(Speech.stop()).catch(() => {}),
            Promise.resolve(handle?.cancel()).catch(() => {}),
          ]);
        },
        async pause() {
          await Speech.pause();
        },
        async resume() {
          await Speech.resume();
        },
      };
    },
  };
}
