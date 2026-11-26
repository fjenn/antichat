/**
 * Which recogniser a phone uses, decided once per session from plain facts.
 *
 * - iOS 26+: Apple's SpeechTranscriber when it has the language on-device. It
 *   streams word by word, costs no app memory and was measured faster than
 *   Whisper large-v3-turbo at similar quality (research 05b §6).
 * - Older iOS: Whisper, except on 4 GB phones (class A), where the legacy
 *   on-device recogniser is used if the language has it: Whisper's ~330 MB
 *   beside the chat model does not fit there.
 * - Android: Whisper. The platform recogniser differs per vendor and often
 *   needs a network, so it is only the class A fallback when it reports
 *   on-device support for the language.
 */
import type {VoiceDeviceClass, VoicePlatform} from '../types';
import type {SttAdapterId} from './types';

export type WhisperTier = 'base' | 'small' | 'large-turbo';

export interface SttFacts {
  platform: VoicePlatform;
  /** "26.1" on iOS, API level ("35") on Android. */
  osVersion: string;
  deviceClass: VoiceDeviceClass;
  /** The system recogniser has the wanted language on-device right now. */
  systemOnDevice: boolean;
  /** Whisper tiers with model files on disk. */
  whisperInstalled: readonly WhisperTier[];
  /** The native system-recogniser module is in this build. */
  systemModule: boolean;
}

export interface SttChoice {
  adapter: SttAdapterId;
  /** Set when `adapter` is 'whisper'. */
  whisperTier?: WhisperTier;
  /** The model file must be downloaded first. */
  needsDownload: boolean;
  reason:
    | 'system_streaming'
    | 'system_low_memory'
    | 'whisper_default'
    | 'whisper_language'
    | 'whisper_no_system_module';
}

export const majorVersion = (version: string): number =>
  parseInt(version.split('.')[0] ?? '0', 10) || 0;

/** Tier a class should run, before looking at what is installed. */
export function whisperTierFor(deviceClass: VoiceDeviceClass): WhisperTier {
  // Measured on the voice fixtures (whisper.cpp, 2026-11-25): base q8
  // (82 MB file, ~330 MB running) 2.8% WER, 6.4% outside English; small q8
  // (264 MB, ~650 MB) 0.7%, 2.1%; large-v3-turbo q5 (574 MB, ~1.2 GB) 0%,
  // at about twice small's decode time. Small from 8 GB (class C) up; base
  // on 4-6 GB phones, whose CPUs would lag behind live partials with small.
  return deviceClass === 'A' || deviceClass === 'B' ? 'base' : 'small';
}

export function selectStt(facts: SttFacts): SttChoice {
  const wanted = whisperTierFor(facts.deviceClass);
  const order: WhisperTier[] =
    wanted === 'small' ? ['small', 'base', 'large-turbo'] : ['base', 'small'];
  const installed = order.find(tier => facts.whisperInstalled.includes(tier));
  const whisper = (reason: SttChoice['reason']): SttChoice => ({
    adapter: 'whisper',
    // Until the wanted tier is on disk, any installed tier beats a download.
    whisperTier: installed ?? (wanted === 'small' ? 'base' : wanted),
    needsDownload: !installed,
    reason,
  });
  const system = (reason: SttChoice['reason']): SttChoice => ({
    adapter: 'system',
    needsDownload: false,
    reason,
  });

  if (!facts.systemModule) {
    return whisper('whisper_no_system_module');
  }
  if (facts.platform === 'ios' && majorVersion(facts.osVersion) >= 26) {
    return facts.systemOnDevice
      ? system('system_streaming')
      : whisper('whisper_language');
  }
  if (facts.deviceClass === 'A' && facts.systemOnDevice) {
    return system('system_low_memory');
  }
  return whisper(facts.systemOnDevice ? 'whisper_default' : 'whisper_language');
}
