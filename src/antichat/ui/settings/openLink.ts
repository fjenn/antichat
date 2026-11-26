import {Linking} from 'react-native';
import {InAppBrowser} from 'react-native-inappbrowser-reborn';

/**
 * Open a web page in the in-app browser sheet (Safari view on iOS, a Custom
 * Tab on Android); the system browser where there is none.
 */
export async function openInAppBrowser(url: string): Promise<void> {
  try {
    if (await InAppBrowser.isAvailable()) {
      await InAppBrowser.open(url, {
        dismissButtonStyle: 'done',
        readerMode: false,
        modalEnabled: true,
        showTitle: true,
        enableDefaultShare: true,
      });
      return;
    }
  } catch {
    // Fall through to the browser.
  }
  await Linking.openURL(url).catch(() => {});
}
