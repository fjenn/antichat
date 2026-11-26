import {useEffect, useMemo, useSyncExternalStore} from 'react';

import type {ChatPort} from '../../../contracts';
import {ThreadController, type ThreadSnapshot} from './ThreadController';

/** The thread of a conversation; a new controller per conversation. */
export function useThread(
  chat: ChatPort,
  conversationId: string,
): {controller: ThreadController; snapshot: ThreadSnapshot} {
  const controller = useMemo(
    () => new ThreadController(chat, conversationId),
    [chat, conversationId],
  );
  useEffect(() => {
    controller.attach();
    return () => controller.dispose();
  }, [controller]);
  const snapshot = useSyncExternalStore(
    controller.subscribe,
    controller.getSnapshot,
    controller.getSnapshot,
  );
  return {controller, snapshot};
}
