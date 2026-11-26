/**
 * Glue between the chat shell and the history milestone: keeps the store's
 * temporary-chat bookkeeping in step with what the shell shows. The thread
 * and sending belong to the chat adapter (`adapters/chat.ts`).
 */
import {reaction} from 'mobx';

import {getPorts} from '../../adapters';
import {shellSession} from '../../app/session';
import type {ConversationPort} from '../../contracts';

type Arming = ConversationPort & {
  armTemporary?: (on: boolean) => void;
  discardTemporary?: (id: string) => Promise<void>;
};

let installed = false;

/**
 * Keeps the store in step with what the shell shows:
 *  - the temporary switch of the new chat arms (or disarms) the store,
 *  - leaving a temporary chat throws it away.
 */
export function installShellBridge(): void {
  if (installed) {
    return;
  }
  installed = true;

  reaction(
    () => shellSession.temporary,
    on => {
      if (shellSession.activeConversationId === null) {
        (getPorts().conversations as Arming).armTemporary?.(on);
      }
    },
  );

  reaction(
    () => shellSession.activeConversationId,
    (_next, previous) => {
      const conversations = getPorts().conversations as Arming;
      if (previous && conversations.get(previous)?.temporary) {
        (conversations.discardTemporary
          ? conversations.discardTemporary(previous)
          : conversations.remove(previous)
        ).catch(() => {});
      }
    },
  );
}
