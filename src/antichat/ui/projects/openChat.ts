import {shellSession} from '../../app/session';
import type {ScreenNavigation} from '../memory/parts';

/** Shows a chat (or the empty new chat with `null`) on the chat screen. */
export function openChat(
  navigation: ScreenNavigation,
  conversationId: string | null,
): void {
  if (conversationId) {
    shellSession.open(conversationId);
  } else {
    shellSession.newChat();
  }
  navigation.navigate('Main', {screen: 'Chat'});
}
