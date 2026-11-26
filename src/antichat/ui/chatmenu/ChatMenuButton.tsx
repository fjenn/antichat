import React, {useMemo} from 'react';
import {observer} from 'mobx-react';

import {getPorts} from '../../adapters';
import {shellSession} from '../../app/session';
import type {ConversationView} from '../../contracts';
import {translate, useT} from '../../locales';
import {
  archiveChat,
  branchChat,
  deleteChat,
  lockChat,
  removeLock,
  shareChat,
  togglePin,
  unarchiveChat,
} from '../drawer/historyActions';
import {historyUi} from '../drawer/historyUi';
import {ContextMenu, IconButton, toast, type MenuItem} from '../primitives';
import {lockState} from './lockState';

export interface ChatMenuButtonProps {
  conversation: ConversationView;
}

/** What the ••• menu offers for a chat, in order. */
export function chatMenuItems(
  conversation: ConversationView,
  t: ReturnType<typeof useT>,
  unlocked: boolean,
): MenuItem[] {
  if (conversation.temporary) {
    return [
      {id: 'save', title: t('temporary.save'), icon: 'check'},
      {
        id: 'delete',
        title: t('chatRow.delete'),
        icon: 'delete',
        destructive: true,
      },
    ];
  }
  // A locked chat that has not been unlocked offers nothing that reads it.
  const readable = !conversation.locked || unlocked;
  return [
    ...(readable
      ? ([
          {id: 'share', title: t('chatRow.share'), icon: 'share'},
          {id: 'rename', title: t('chatRow.rename'), icon: 'rename'},
        ] satisfies MenuItem[])
      : []),
    ...(conversation.archived
      ? []
      : ([
          {
            id: 'pin',
            title: t(conversation.pinned ? 'chatRow.unpin' : 'chatRow.pin'),
            icon: conversation.pinned ? 'unpin' : 'pin',
          },
        ] satisfies MenuItem[])),
    ...(readable
      ? ([
          {id: 'branch', title: t('chatMenu.branch'), icon: 'branch'},
        ] satisfies MenuItem[])
      : []),
    conversation.archived
      ? {id: 'unarchive', title: t('chatRow.unarchive'), icon: 'unarchive'}
      : {id: 'archive', title: t('chatRow.archive'), icon: 'archive'},
    conversation.locked
      ? {id: 'unlock', title: t('chatMenu.removeLock'), icon: 'unlock'}
      : {id: 'lock', title: t('chatMenu.lock'), icon: 'lock'},
    {
      id: 'delete',
      title: t('chatRow.delete'),
      icon: 'delete',
      destructive: true,
    },
  ];
}

/** Carries out a ••• menu choice. */
export function runChatMenuAction(
  action: string,
  conversation: ConversationView,
): void {
  const {conversations} = getPorts();
  switch (action) {
    case 'share':
      shareChat(conversation);
      break;
    case 'rename':
      historyUi.openRenameDialog(conversation);
      break;
    case 'pin':
      togglePin(conversation);
      break;
    case 'branch':
      branchChat(conversation).catch(() => {});
      break;
    case 'archive':
      archiveChat(conversation);
      break;
    case 'unarchive':
      unarchiveChat(conversation);
      break;
    case 'lock':
      lockChat(conversation).catch(() => {});
      break;
    case 'unlock':
      removeLock(conversation).catch(() => {});
      break;
    case 'delete':
      if (conversation.temporary) {
        // Nothing of a temporary chat is kept, so there is nothing to undo.
        shellSession.newChat();
        conversations.remove(conversation.id).catch(() => {});
      } else {
        deleteChat(conversation);
      }
      break;
    case 'save':
      conversations
        .saveTemporary(conversation.id)
        .then(() => {
          shellSession.setTemporary(false);
          toast.show({message: translate('temporary.saved')});
        })
        .catch(() =>
          toast.show({message: translate('errors.generic'), kind: 'error'}),
        );
      break;
  }
}

/** The ••• button of the chat's top bar and its menu. */
export const ChatMenuButton = observer(function ChatMenu({
  conversation,
}: ChatMenuButtonProps) {
  const t = useT();
  const unlocked = lockState.isUnlocked(conversation.id);
  const items = useMemo(
    () => chatMenuItems(conversation, t, unlocked),
    [conversation, t, unlocked],
  );
  return (
    <ContextMenu
      testID="chat-menu"
      items={items}
      onSelect={action => runChatMenuAction(action, conversation)}>
      <IconButton
        testID="chat-more"
        icon="more"
        accessibilityLabel={t('shell.moreActions')}
      />
    </ContextMenu>
  );
});
