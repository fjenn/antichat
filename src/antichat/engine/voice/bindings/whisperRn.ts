/**
 * Whisper through PocketPal's `whisperAsrEngine` (whisper.rn): its model
 * install, context cache and cancel logic are reused as they are.
 */
import {fromByteArray} from 'base64-js';

import {whisperAsrEngine} from '../../../../services/asr';
import type {AsrTier} from '../../../../services/asr';
import {pcmToBytes} from '../audio/pcm';
import type {WhisperBackend} from '../stt/whisperAdapter';
import {voiceError} from '../types';

const BUSY_RETRIES = 40;
const BUSY_WAIT_MS = 25;

export function createWhisperRnBackend(tier: () => AsrTier): WhisperBackend {
  return {
    async transcribe(pcm, options) {
      const audio = fromByteArray(pcmToBytes(pcm));
      // whisper.rn resolves a decode a moment before its context is free
      // again, so a decode queued right behind one can be refused: wait and
      // retry (seen on iOS with back-to-back partial and final decodes).
      for (let attempt = 0; ; attempt++) {
        try {
          const result = await whisperAsrEngine.transcribe(audio, {
            tier: tier(),
            language: options.language,
            prompt: options.prompt,
          });
          return {text: result.text, language: result.language};
        } catch (err) {
          const busy = /already transcribing/i.test(String(err));
          if (!busy || attempt >= BUSY_RETRIES) {
            throw err;
          }
          await new Promise(resolve => setTimeout(resolve, BUSY_WAIT_MS));
        }
      }
    },
    cancel: () => whisperAsrEngine.cancelTranscription(),
    async preload() {
      // Said as its own error: the UI offers the download instead of "retry".
      if (!(await whisperAsrEngine.isInstalled(tier()))) {
        throw voiceError('model_missing', `whisper ${tier()} is not installed`);
      }
      await whisperAsrEngine.preload(tier());
    },
    release: () => whisperAsrEngine.release(),
  };
}

/** Whisper tiers whose model files are on the phone. */
export async function installedWhisperTiers(): Promise<AsrTier[]> {
  const tiers: AsrTier[] = ['base', 'small', 'large-turbo'];
  const present = await Promise.all(
    tiers.map(tier => whisperAsrEngine.isInstalled(tier)),
  );
  return tiers.filter((_, index) => present[index]);
}
