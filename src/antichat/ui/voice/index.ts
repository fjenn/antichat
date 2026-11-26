/**
 * Voice UI (M11). Version 1 is dictation only: the app uses `register.tsx`
 * (`registerVoiceUi(host)`, `DictationLayer`, `DictationButton`) and
 * `DictationSettings`.
 *
 * Read-aloud (ReadAloud.tsx), voice mode (VoiceModeDock.tsx, VoiceOrb.tsx)
 * and the voice picker (VoicePicker.tsx) are out of version 1: the files and
 * their tests stay, but nothing exports or mounts them.
 */
export {DictationBar, type DictationBarProps} from './DictationBar';
export {DictationSettings} from './DictationSettings';
export {Waveform} from './Waveform';
export {asVoicePort, getVoicePort} from './port';
export {
  DictationButton,
  DictationLayer,
  registerVoiceUi,
  useDictating,
  voiceUi,
  type VoiceUiHost,
} from './register';
export {voiceStrings} from './strings';
