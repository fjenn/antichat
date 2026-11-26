/**
 * Local notifications (M5: "download finished"), through
 * react-native-notify-kit. Nothing is sent anywhere; these are on-device
 * notices only.
 *
 * iOS also posts a native notice from `AntiChatDownloadCore` when the files
 * arrive while the app is suspended and no JavaScript runs; the wording for
 * that one is passed along with the download (`downloadNotice`).
 */
import {AppState, Platform} from 'react-native';
import notifee, {
  AndroidImportance,
  AuthorizationStatus,
} from 'react-native-notify-kit';

const CHANNEL_ID = 'antichat_models';

// TODO(copy): move to the copy deck with the M6 first-run UI. No model names:
// the first-run flow never shows one unless the user opens "Details".
export const downloadNotice = () => ({
  title: 'Download finished',
  body: 'Open AntiChat to start chatting.',
});

const readyNotice = () => ({
  title: 'Your assistant is ready',
  body: 'Open AntiChat to start chatting.',
});

const sleep = (ms: number) =>
  new Promise<void>(resolve => setTimeout(resolve, ms));

/**
 * Ask for permission to show notifications. Called when a download starts,
 * never at launch. Resolves false when the user said no; nothing else changes.
 */
export async function requestNotificationPermission(): Promise<boolean> {
  try {
    const settings = await notifee.requestPermission();
    return (
      settings.authorizationStatus === AuthorizationStatus.AUTHORIZED ||
      settings.authorizationStatus === AuthorizationStatus.PROVISIONAL
    );
  } catch {
    return false;
  }
}

/**
 * "Your assistant is ready", shown only when the app is not in front: in the
 * foreground the screen already shows it.
 */
export async function notifyModelReady(modelId: string): Promise<boolean> {
  // A download that ended while the app was suspended is processed at the
  // moment the user comes back; give the app state a moment to say so.
  await sleep(1500);
  if (AppState.currentState !== 'background') {
    return false;
  }
  try {
    if (Platform.OS === 'android') {
      await notifee.createChannel({
        id: CHANNEL_ID,
        name: 'Assistant downloads',
        importance: AndroidImportance.DEFAULT,
      });
    }
    await notifee.displayNotification({
      // Same id as the native iOS notice, so the two never stack.
      id: `antichat.download.${modelId}`,
      ...readyNotice(),
      android: {channelId: CHANNEL_ID, pressAction: {id: 'default'}},
    });
    return true;
  } catch {
    return false;
  }
}
