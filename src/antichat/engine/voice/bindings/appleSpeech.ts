/**
 * Apple's on-device SpeechTranscriber (iOS 26+) as a system recogniser,
 * through the native module of `@react-native-ai/apple` 0.13
 * (`NativeAppleTranscription`).
 *
 * The package's own JS wrapper is NOT loaded: it imports
 * `@ai-sdk/provider-utils`, whose module init touches `TransformStream` and
 * `TextDecoder`, which Hermes does not have. Metro reports a throw during a
 * lazy module init as fatal even inside try/catch, so the first tap on the
 * microphone closed the app (Release, iOS 26). The few lines of that wrapper
 * this app needs are below, talking to the TurboModule directly.
 *
 * `loadAppleTranscription()` gives the module on iOS 26+ and undefined
 * elsewhere (Android, older iOS, a build without the pod).
 */
import {Platform, TurboModuleRegistry} from 'react-native';

import type {
  SystemRecognizerBackend,
  SystemRecognizerEvent,
  SystemRecognizerSupport,
  SystemRecognizerTask,
} from '../stt/systemAdapter';
import {SAMPLE_RATE} from '../types';

/** The part of `AppleTranscription` used here (same names and shapes). */
export interface AppleTranscriptionModule {
  getModelInfo(language: string): Promise<{
    isAvailable: boolean;
    supportsLocale: boolean;
    locale?: string;
    assets?: 'installed' | 'downloading' | 'supported' | 'unsupported';
    supportedLocales: string[];
  }>;
  /** Installs the locale's assets (a system download, shared by all apps). */
  prepare(language: string): Promise<void>;
  transcribeStream(options: {
    language: string;
    sampleRate: number;
    encoding?: 'int16' | 'float32';
    onResult: (result: {text: string; isFinal: boolean}) => void;
    onError?: (error: Error) => void;
  }): Promise<{
    append(audio: ArrayBufferLike | ArrayBufferView): void;
    stop(): Promise<void>;
  }>;
}

interface Subscription {
  remove(): void;
}

/** `NativeAppleTranscription`'s spec (the members used here). */
interface NativeTranscription {
  getModelInfo(language: string): Promise<unknown>;
  prepare(language: string): Promise<void>;
  startStreamTranscription(
    sessionId: string,
    language: string,
    sampleRate: number,
    encoding: string,
  ): Promise<void>;
  stopLiveTranscription(sessionId: string): Promise<void>;
  onLiveTranscriptionResult(
    listener: (event: {
      sessionId: string;
      text: string;
      isFinal: boolean;
    }) => void,
  ): Subscription;
  onLiveTranscriptionError(
    listener: (event: {sessionId: string; error: string}) => void,
  ): Subscription;
}

type AppendAudio = (sessionId: string, audio: ArrayBuffer) => void;

let sessionCounter = 0;

/** The JS side of `@react-native-ai/apple`'s stream transcription. */
export function wrapNativeTranscription(
  native: NativeTranscription,
  appendAudio: () => AppendAudio | undefined = () =>
    (globalThis as {__apple__llm__append_transcription_audio__?: AppendAudio})
      .__apple__llm__append_transcription_audio__,
): AppleTranscriptionModule {
  return {
    getModelInfo: language =>
      native.getModelInfo(language) as ReturnType<
        AppleTranscriptionModule['getModelInfo']
      >,
    prepare: language => native.prepare(language),
    async transcribeStream({
      language,
      sampleRate,
      encoding = 'int16',
      onResult,
      onError,
    }) {
      const sessionId = `antichat-${Date.now().toString(36)}-${++sessionCounter}`;
      // Native events: a throw in a listener would be fatal, so none escapes.
      const listeners = [
        native.onLiveTranscriptionResult(event => {
          if (event?.sessionId !== sessionId) {
            return;
          }
          try {
            onResult({
              text: String(event.text ?? ''),
              isFinal: !!event.isFinal,
            });
          } catch (error) {
            console.warn(`[voice] Apple result handler: ${error}`);
          }
        }),
        native.onLiveTranscriptionError(event => {
          if (event?.sessionId !== sessionId) {
            return;
          }
          try {
            onError?.(new Error(String(event.error)));
          } catch (error) {
            console.warn(`[voice] Apple error handler: ${error}`);
          }
        }),
      ];
      const removeListeners = () =>
        listeners.forEach(listener => {
          try {
            listener?.remove();
          } catch {}
        });
      try {
        await native.startStreamTranscription(
          sessionId,
          language,
          sampleRate,
          encoding,
        );
      } catch (error) {
        removeListeners();
        throw error;
      }
      let stopping: Promise<void> | undefined;
      return {
        // Throws when the native session is gone or the audio is refused;
        // the caller catches.
        append(audio) {
          if (stopping) {
            return;
          }
          const append = appendAudio();
          if (typeof append !== 'function') {
            throw new Error('Apple transcription audio binding is missing');
          }
          const view = ArrayBuffer.isView(audio) ? audio : null;
          append(
            sessionId,
            view
              ? (view.buffer.slice(
                  view.byteOffset,
                  view.byteOffset + view.byteLength,
                ) as ArrayBuffer)
              : (audio as ArrayBuffer),
          );
        },
        stop: () =>
          (stopping ??= Promise.resolve()
            .then(() => native.stopLiveTranscription(sessionId))
            .then(() => {})
            .finally(removeListeners)),
      };
    },
  };
}

export function loadAppleTranscription(): AppleTranscriptionModule | undefined {
  if (
    Platform.OS !== 'ios' ||
    (parseInt(String(Platform.Version), 10) || 0) < 26
  ) {
    return undefined;
  }
  try {
    // `get`, not `getEnforcing`: null in a build without the pod.
    const native = TurboModuleRegistry.get(
      'NativeAppleTranscription',
    ) as unknown as NativeTranscription | null;
    if (
      !native ||
      typeof native.startStreamTranscription !== 'function' ||
      typeof native.onLiveTranscriptionResult !== 'function'
    ) {
      console.log('[voice] Apple transcription module missing');
      return undefined;
    }
    return wrapNativeTranscription(native);
  } catch (error) {
    console.log(`[voice] Apple transcription module missing: ${error}`);
    return undefined;
  }
}

export function createAppleSpeechBackend(
  module: AppleTranscriptionModule,
): SystemRecognizerBackend {
  return {
    async supportedLocales(): Promise<string[]> {
      const info = await module.getModelInfo('en');
      return info.isAvailable ? info.supportedLocales : [];
    },

    async support(locale: string): Promise<SystemRecognizerSupport | null> {
      const info = await module.getModelInfo(locale);
      if (!info.isAvailable || !info.supportsLocale || !info.locale) {
        return null;
      }
      return {
        // Only installed assets work in airplane mode.
        onDevice: info.assets === 'installed',
        locale: info.locale,
        // SpeechAnalyzer has no task length limit.
        maxTaskMs: undefined,
        punctuation: true,
      };
    },

    prepare: locale => module.prepare(locale),

    start(options, onEvent): SystemRecognizerTask {
      let aborted = false;
      let broken = false;
      const backlog: Int16Array[] = [];
      let stream: Awaited<
        ReturnType<AppleTranscriptionModule['transcribeStream']>
      > | null = null;
      const emit = (event: SystemRecognizerEvent) => {
        if (aborted || broken) {
          return;
        }
        if (event.type === 'error') {
          // One error per task; the session falls back from here.
          broken = true;
        }
        try {
          onEvent(event);
        } catch (error) {
          console.warn(`[voice] Apple event handler: ${error}`);
        }
      };
      const fail = (error: unknown) =>
        emit({
          type: 'error',
          message: String(error instanceof Error ? error.message : error),
        });
      // Runs on the microphone's callback: a throw there closes the app.
      const append = (pcm: Int16Array) => {
        try {
          stream?.append(pcm);
        } catch (error) {
          fail(error);
        }
      };
      const ready = Promise.resolve()
        .then(() =>
          module.transcribeStream({
            language: options.locale,
            sampleRate: SAMPLE_RATE,
            encoding: 'int16',
            // Volatile results replace each other; a final result settles
            // its stretch and the next volatile one starts after it.
            onResult: result =>
              emit({
                type: result.isFinal ? 'final' : 'partial',
                text: result.text,
              }),
            onError: error => fail(error),
          }),
        )
        .then(opened => {
          stream = opened;
          if (aborted) {
            return opened.stop();
          }
          backlog.forEach(append);
          backlog.length = 0;
        })
        .catch(fail);
      return {
        feed(pcm) {
          if (aborted || broken) {
            return;
          }
          if (stream) {
            append(pcm);
          } else {
            backlog.push(pcm);
          }
        },
        async end() {
          await ready;
          await stream?.stop();
        },
        abort() {
          aborted = true;
          try {
            stream?.stop().catch(() => {});
          } catch {}
        },
      };
    },
  };
}
