/**
 * First run: the welcome screen, the gate that shows it once, the download
 * card for the chat screen and the composer's readiness.
 */
export {FirstRunGate} from './FirstRunGate';
export {WelcomeScreen, type WelcomeScreenProps} from './WelcomeScreen';
export {SetupCard, type SetupCardProps} from './SetupCard';
export {ModelNotices} from './ModelNotices';
export {ProgressBar, type ProgressBarProps} from './ProgressBar';
export {
  useComposerReadiness,
  type ComposerReadiness,
} from './useComposerReadiness';
export {composerHint, setupWording, timeLeft} from './wording';
export {
  notificationPermission,
  notifyAssistantReady,
  requestNotificationPermission,
} from './notifications';
