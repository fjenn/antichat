/**
 * The one notification of first run: "Your assistant is ready", shown only
 * when the app is not in front. Permission is asked when the user taps
 * "Notify me when it's ready" on the download card, never at launch.
 * On-device only; nothing is sent anywhere.
 */
import {AppState, Platform} from 'react-native';

import {translate} from '../../locales';

const CHANNEL_ID = 'antichat_models';

interface NotifyKit {
  requestPermission(): Promise<{authorizationStatus: number}>;
  getNotificationSettings(): Promise<{authorizationStatus: number}>;
  createChannel(channel: {
    id: string;
    name: string;
    importance: number;
  }): Promise<string>;
  displayNotification(notification: Record<string, unknown>): Promise<string>;
}

/** notify-kit's `AuthorizationStatus`. */
const AUTHORIZED = 1;
const PROVISIONAL = 2;
const NOT_DETERMINED = -1;
/** notify-kit's `AndroidImportance.DEFAULT`. */
const IMPORTANCE_DEFAULT = 3;

function kit(): NotifyKit | null {
  try {
    return require('react-native-notify-kit').default as NotifyKit;
  } catch {
    return null;
  }
}

const allowed = (status: number) =>
  status === AUTHORIZED || status === PROVISIONAL;

export type NotificationPermission = 'granted' | 'denied' | 'undetermined';

export async function notificationPermission(): Promise<NotificationPermission> {
  try {
    const settings = await kit()?.getNotificationSettings();
    if (!settings) {
      return 'denied';
    }
    if (allowed(settings.authorizationStatus)) {
      return 'granted';
    }
    return settings.authorizationStatus === NOT_DETERMINED
      ? 'undetermined'
      : 'denied';
  } catch {
    return 'denied';
  }
}

/** Shows the system question. Resolves false when the user said no. */
export async function requestNotificationPermission(): Promise<boolean> {
  try {
    const settings = await kit()?.requestPermission();
    return settings ? allowed(settings.authorizationStatus) : false;
  } catch {
    return false;
  }
}

/** Posts the notice unless the app is in front. Resolves whether it was shown. */
export async function notifyAssistantReady(modelId: string): Promise<boolean> {
  if (AppState.currentState === 'active') {
    return false;
  }
  const notifee = kit();
  if (!notifee || (await notificationPermission()) !== 'granted') {
    return false;
  }
  try {
    if (Platform.OS === 'android') {
      await notifee.createChannel({
        id: CHANNEL_ID,
        name: translate('setup.notification.channel'),
        importance: IMPORTANCE_DEFAULT,
      });
    }
    await notifee.displayNotification({
      // Same id as M5's native iOS notice, so the two never stack.
      id: `antichat.download.${modelId}`,
      title: translate('setup.notification.title'),
      body: translate('setup.notification.body'),
      android: {channelId: CHANNEL_ID, pressAction: {id: 'default'}},
    });
    return true;
  } catch {
    return false;
  }
}
