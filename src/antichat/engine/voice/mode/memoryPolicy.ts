/**
 * Which speech models may be loaded beside the chat model, per device class.
 *
 * The chat model always stays loaded in a voice session (reloading it costs
 * seconds per turn). What changes with the class is which recogniser and
 * voice may sit next to it, and how long they stay after use:
 *
 * | Class | Voice mode | Recogniser in session | Voice in session | After dictation |
 * | A 4 GB  | only with system recogniser + system voice (0 MB in the app) | system | system | Whisper unloaded at once |
 * | B 6 GB  | yes | Whisper base (~330 MB) | ≤ 200 MB engine, else system | unloaded at once |
 * | C 8 GB  | yes | Whisper base | any | kept 30 s |
 * | D 12 GB | yes | Whisper small (~650 MB) | any | kept 2 min |
 * | E 16 GB | yes | Whisper small | any | kept 2 min |
 *
 * When the measured free memory is known and the plan does not fit, the
 * voice falls back to the system voice first, then the recogniser to the
 * system one; if neither helps, voice mode is refused with a reason.
 */
import type {SttChoice, WhisperTier} from '../stt/select';
import {SYSTEM_VOICE, voiceCost, type CatalogVoice} from '../tts/voices';
import type {VoiceDeviceClass, VoicePlatform} from '../types';

export const WHISPER_RUNTIME_BYTES: Record<WhisperTier, number> = {
  base: 330_000_000,
  small: 650_000_000,
  'large-turbo': 1_200_000_000,
};

export interface MemoryPlanInputs {
  deviceClass: VoiceDeviceClass;
  platform: VoicePlatform;
  stt: SttChoice;
  voice: CatalogVoice;
  /** The system recogniser could be used instead (language is on-device). */
  systemSttAvailable: boolean;
  /**
   * Memory the app may still take with the chat model loaded, when measured
   * (`os_proc_available_memory`, `MemoryInfo.availMem`).
   */
  freeBytes?: number;
}

export interface VoiceMemoryPlan {
  voiceMode: 'full' | 'system_only' | 'unavailable';
  reason?: 'class_too_small' | 'out_of_memory';
  stt: SttChoice;
  voice: CatalogVoice;
  /** Bytes the speech models add while a voice session runs. */
  sessionBytes: number;
  /** Keep the recogniser loaded this long after a dictation ends. */
  dictationWarmMs: number;
  /** Keep the voice's engine loaded this long after speech ends. */
  voiceWarmMs: number;
  /** What was changed to make it fit. */
  downgrades: ('voice_to_system' | 'stt_to_system')[];
}

const WARM_MS: Record<VoiceDeviceClass, {stt: number; tts: number}> = {
  A: {stt: 0, tts: 0},
  B: {stt: 0, tts: 0},
  C: {stt: 30_000, tts: 60_000},
  D: {stt: 120_000, tts: 300_000},
  E: {stt: 120_000, tts: 300_000},
};

/** Largest voice engine a class may hold beside recogniser and chat model. */
const VOICE_CAP_BYTES: Record<VoiceDeviceClass, number> = {
  A: 0,
  B: 210_000_000,
  C: 550_000_000,
  D: 550_000_000,
  E: 550_000_000,
};

/** Share of the measured free memory the speech models may take. */
const FREE_SHARE = 0.8;

const SYSTEM_STT: SttChoice = {
  adapter: 'system',
  needsDownload: false,
  reason: 'system_low_memory',
};

export function planVoiceMemory(inputs: MemoryPlanInputs): VoiceMemoryPlan {
  const {deviceClass, platform} = inputs;
  const warm = WARM_MS[deviceClass];
  const downgrades: VoiceMemoryPlan['downgrades'] = [];
  let stt = inputs.stt;
  let voice = inputs.voice;

  const sttBytes = () =>
    stt.adapter === 'whisper'
      ? WHISPER_RUNTIME_BYTES[stt.whisperTier ?? 'base']
      : 0;
  const voiceBytes = () => voiceCost(voice, platform).runtimeBytes;
  const plan = (
    voiceMode: VoiceMemoryPlan['voiceMode'],
    reason?: VoiceMemoryPlan['reason'],
  ): VoiceMemoryPlan => ({
    voiceMode,
    reason,
    stt,
    voice,
    sessionBytes: sttBytes() + voiceBytes(),
    dictationWarmMs: warm.stt,
    voiceWarmMs: warm.tts,
    downgrades,
  });

  if (voiceBytes() > VOICE_CAP_BYTES[deviceClass]) {
    voice = SYSTEM_VOICE;
    downgrades.push('voice_to_system');
  }
  if (deviceClass === 'A') {
    // Nothing neural beside the chat model on 4 GB.
    if (stt.adapter !== 'system') {
      if (!inputs.systemSttAvailable) {
        return plan('unavailable', 'class_too_small');
      }
      stt = SYSTEM_STT;
      downgrades.push('stt_to_system');
    }
    return plan('system_only');
  }

  if (inputs.freeBytes !== undefined && inputs.freeBytes > 0) {
    const budget = inputs.freeBytes * FREE_SHARE;
    if (sttBytes() + voiceBytes() > budget && voice.engine !== 'system') {
      voice = SYSTEM_VOICE;
      downgrades.push('voice_to_system');
    }
    if (sttBytes() > budget && stt.adapter === 'whisper') {
      if (stt.whisperTier !== 'base' && WHISPER_RUNTIME_BYTES.base <= budget) {
        stt = {...stt, whisperTier: 'base'};
      } else if (inputs.systemSttAvailable) {
        stt = SYSTEM_STT;
        downgrades.push('stt_to_system');
      } else {
        return plan('unavailable', 'out_of_memory');
      }
    }
  }
  return plan(
    stt.adapter === 'system' && voice.engine === 'system'
      ? 'system_only'
      : 'full',
  );
}
