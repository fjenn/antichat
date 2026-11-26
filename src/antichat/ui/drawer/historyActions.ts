/**
 * Everything a person can do to a chat from a list: the drawer rows, the
 * search results, the archive list and the chat's own ••• menu all call
 * these, so an action behaves the same wherever it is started.
 *
 * Nothing here blocks with a confirmation. Archive and delete happen at once
 * and offer "Undo" in a toast; a delete is only carried out when its undo
 * time has passed (or the app leaves the foreground).
 */
import {AppState} from 'react-native';

import {getPorts} from '../../adapters';
import {isHistoryPort} from '../../adapters/history';
import {shellSession} from '../../app/session';
import type {ConversationView} from '../../contracts';
import {translate} from '../../locales';
import {deviceUnlock} from '../chatmenu/deviceUnlock';
import {lockState, unlockChat, verifyOwner} from '../chatmenu/lockState';
import {haptics, toast} from '../primitives';
import {historyUi} from './historyUi';

/** How long "Undo" stays available after a delete. */
export const UNDO_MS = 5000;

function failed(): void {
  toast.show({message: translate('errors.generic'), kind: 'error'});
}

function leaveIfOpen(conversationId: string): void {
  if (shellSession.activeConversationId === conversationId) {
    shellSession.newChat();
  }
}

// ----------------------------------------------------------------- delete

interface PendingDelete {
  conversation: ConversationView;
  timer: ReturnType<typeof setTimeout>;
  wasOpen: boolean;
}

const pending = new Map<string, PendingDelete>();
let watchingAppState = false;

function publishPending(): void {
  historyUi.setPendingDeletes(new Set(pending.keys()));
}

function commitDelete(conversationId: string): void {
  const entry = pending.get(conversationId);
  if (!entry) {
    return;
  }
  clearTimeout(entry.timer);
  pending.delete(conversationId);
  lockState.forget(conversationId);
  getPorts()
    .conversations.remove(conversationId)
    .catch(failed)
    .finally(publishPending);
}

/** Carries out every delete that is still waiting for its undo. */
export function flushPendingDeletes(): void {
  [...pending.keys()].forEach(commitDelete);
}

function undoDelete(conversationId: string): void {
  const entry = pending.get(conversationId);
  if (!entry) {
    return;
  }
  clearTimeout(entry.timer);
  pending.delete(conversationId);
  publishPending();
  if (entry.wasOpen && shellSession.activeConversationId === null) {
    shellSession.open(conversationId);
  }
}

/** The row goes at once; the chat is deleted when "Undo" has run out. */
export function deleteChat(conversation: ConversationView): void {
  // One undo at a time: an earlier delete is final once another starts.
  flushPendingDeletes();
  if (!watchingAppState) {
    watchingAppState = true;
    AppState.addEventListener('change', state => {
      if (state !== 'active') {
        flushPendingDeletes();
      }
    });
  }
  const {id} = conversation;
  const wasOpen = shellSession.activeConversationId === id;
  pending.set(id, {
    conversation,
    wasOpen,
    timer: setTimeout(() => commitDelete(id), UNDO_MS),
  });
  publishPending();
  leaveIfOpen(id);
  toast.show({
    message: translate('toast.chatDeleted'),
    duration: UNDO_MS,
    action: {label: translate('common.undo'), onPress: () => undoDelete(id)},
  });
}

// ---------------------------------------------------------- pin, archive

export function togglePin(conversation: ConversationView): void {
  const pinned = !conversation.pinned;
  haptics.selection();
  getPorts().conversations.setPinned(conversation.id, pinned).catch(failed);
  toast.show({
    message: translate(pinned ? 'toast.chatPinned' : 'toast.chatUnpinned'),
  });
}

export function archiveChat(conversation: ConversationView): void {
  const {conversations} = getPorts();
  const {id, pinned} = conversation;
  const wasOpen = shellSession.activeConversationId === id;
  conversations.setArchived(id, true).catch(failed);
  leaveIfOpen(id);
  toast.show({
    message: translate('toast.chatArchived'),
    action: {
      label: translate('common.undo'),
      onPress: () => {
        conversations
          .setArchived(id, false)
          .then(() => (pinned ? conversations.setPinned(id, true) : undefined))
          .catch(failed);
        if (wasOpen && shellSession.activeConversationId === null) {
          shellSession.open(id);
        }
      },
    },
  });
}

export function unarchiveChat(conversation: ConversationView): void {
  getPorts().conversations.setArchived(conversation.id, false).catch(failed);
  toast.show({message: translate('toast.chatUnarchived')});
}

// ----------------------------------------------------------------- rename

/** Saves a new title; an empty or unchanged one is ignored. */
export function renameChat(
  conversation: ConversationView,
  title: string,
): void {
  const clean = title.replace(/\s+/g, ' ').trim();
  if (!clean || clean === conversation.title) {
    return;
  }
  getPorts().conversations.rename(conversation.id, clean).catch(failed);
}

// ------------------------------------------------------------------- lock

/** Locks a chat. The owner proves it can be unlocked again first. */
export async function lockChat(conversation: ConversationView): Promise<void> {
  if (!(await deviceUnlock().available())) {
    toast.show({message: translate('lock.unavailable'), kind: 'error'});
    return;
  }
  if ((await verifyOwner()) !== 'ok') {
    return;
  }
  try {
    await getPorts().conversations.setLocked(conversation.id, true);
    // The person who just locked it keeps reading until they leave the app.
    lockState.markUnlocked(conversation.id);
    toast.show({message: translate('toast.chatLocked')});
  } catch {
    failed();
  }
}

/** Removes the lock for good (after the owner has proved who they are). */
export async function removeLock(
  conversation: ConversationView,
): Promise<void> {
  if ((await verifyOwner()) !== 'ok') {
    return;
  }
  try {
    await getPorts().conversations.setLocked(conversation.id, false);
    lockState.forget(conversation.id);
    toast.show({message: translate('toast.chatUnlocked')});
  } catch {
    failed();
  }
}

// ------------------------------------------------------------------- open

/**
 * Shows a chat. A locked one asks the phone to verify its owner first and
 * stays closed if that fails. Resolves to whether the chat was opened.
 */
export async function openChat(
  conversation: ConversationView,
  focus?: {messageId?: string; query?: string},
): Promise<boolean> {
  if (conversation.locked && !(await unlockChat(conversation.id))) {
    return false;
  }
  shellSession.open(conversation.id, focus);
  return true;
}

// ----------------------------------------------------------------- branch

/** Id of the last message of a chat's visible thread. */
async function lastMessageId(conversationId: string): Promise<string | null> {
  const {chat, conversations} = getPorts();
  // The store knows its own message ids; the fake chat only knows the fake's.
  if (isHistoryPort(conversations)) {
    const thread = await conversations.thread(conversationId);
    return thread.length > 0 ? thread[thread.length - 1].id : null;
  }
  const shown = chat.messages(conversationId);
  return shown.length > 0 ? shown[shown.length - 1].id : null;
}

/** Copies the whole visible thread into a new chat and opens it. */
export async function branchChat(
  conversation: ConversationView,
  messageId?: string,
): Promise<void> {
  try {
    const from = messageId ?? (await lastMessageId(conversation.id));
    if (!from) {
      toast.show({message: translate('toast.nothingToBranch')});
      return;
    }
    const branch = await getPorts().conversations.branch(conversation.id, from);
    if (conversation.locked) {
      // A branch of an open locked chat is readable by the same person.
      lockState.markUnlocked(branch.id);
    }
    shellSession.open(branch.id);
    toast.show({message: translate('toast.chatBranched')});
  } catch {
    failed();
  }
}

// ------------------------------------------------------------------ share

export function shareChat(conversation: ConversationView): void {
  historyUi.openShare(conversation);
}
