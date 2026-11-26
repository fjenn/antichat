import '../../../testing/setup';

import React from 'react';
import {act, fireEvent, render, screen} from '@testing-library/react-native';

import {setPorts} from '../../../adapters';
import {shellSession} from '../../../app/session';
import type {ConversationView} from '../../../contracts';
import {createFakePorts, type FakePorts} from '../../../contracts/fakes';
import {translate} from '../../../locales';
import {flushPendingDeletes} from '../../drawer/historyActions';
import {historyUi} from '../../drawer/historyUi';
import {toast} from '../../primitives';
import {
  ChatMenuButton,
  chatMenuItems,
  runChatMenuAction,
} from '../ChatMenuButton';
import {setDeviceUnlock, type UnlockResult} from '../deviceUnlock';
import {exportChat} from '../exportChat';
import {getPorts} from '../../../adapters';
import {LockedChatGate} from '../LockedChatGate';
import {lockState} from '../lockState';
import {RenameDialog} from '../RenameDialog';
import {installShellBridge} from '../shellBridge';
import {TemporaryToggle} from '../TemporaryChat';

const ids = (conversation: ConversationView, unlocked = false) =>
  chatMenuItems(conversation, translate, unlocked).map(item => item.id);

/** The first message of a new chat, as the chat screen sends it. */
async function sendFromShell(text: string): Promise<void> {
  const {conversations, chat} = getPorts();
  const temporary = shellSession.temporary;
  const target = temporary
    ? (await conversations.create({temporary: true})).id
    : null;
  const result = await chat.send(target, {text});
  if (temporary) {
    shellSession.openTemporary(result.conversationId);
  } else {
    shellSession.open(result.conversationId);
  }
}

const settle = async () => {
  await act(async () => {
    for (let i = 0; i < 6; i++) {
      await Promise.resolve();
    }
  });
};

describe('chat menu', () => {
  let ports: FakePorts;
  let unlockAnswer: UnlockResult;
  let available: boolean;
  let prompts: number;

  beforeAll(() => installShellBridge());

  beforeEach(() => {
    ports = createFakePorts({chat: {tokensPerSecond: 10_000, firstTokenMs: 0}});
    setPorts(ports);
    shellSession.newChat();
    lockState.lockAll();
    historyUi.openRenameDialog(null);
    historyUi.openShare(null);
    toast.hide();
    unlockAnswer = 'ok';
    available = true;
    prompts = 0;
    setDeviceUnlock({
      available: async () => available,
      authenticate: async () => {
        prompts++;
        return unlockAnswer;
      },
    });
  });
  afterEach(() => {
    flushPendingDeletes();
    setDeviceUnlock();
    setPorts();
  });

  const chat = () => ports.conversations.conversations[2];
  const fresh = () => ports.conversations.get(chat().id)!;

  it('offers the full menu for a saved chat, in order', () => {
    expect(ids(chat())).toEqual([
      'share',
      'rename',
      'pin',
      'branch',
      'archive',
      'lock',
      'delete',
    ]);
  });

  it('adapts to temporary, archived and locked chats', () => {
    expect(ids({...chat(), temporary: true})).toEqual(['save', 'delete']);
    expect(ids({...chat(), archived: true})).toEqual([
      'share',
      'rename',
      'branch',
      'unarchive',
      'lock',
      'delete',
    ]);
    // Locked and not unlocked: nothing that reads the chat.
    expect(ids({...chat(), locked: true})).toEqual([
      'pin',
      'archive',
      'unlock',
      'delete',
    ]);
    expect(ids({...chat(), locked: true}, true)).toContain('share');
  });

  it('renders the ••• button with the menu behind it', () => {
    render(<ChatMenuButton conversation={chat()} />);
    expect(screen.getByTestId('chat-more')).toBeTruthy();
    expect(screen.getByTestId('chat-menu').props.actions).toHaveLength(7);
  });

  it('branches into a new chat and opens it', async () => {
    const source = chat();
    shellSession.open(source.id);
    ports.chat.seed(source.id, source.title);
    runChatMenuAction('branch', source);
    await settle();
    const opened = shellSession.activeConversationId!;
    expect(opened).not.toBe(source.id);
    expect(ports.conversations.get(opened)?.branchedFrom?.conversationId).toBe(
      source.id,
    );
  });

  it('says so when there is nothing to branch', async () => {
    const empty = await ports.conversations.create();
    runChatMenuAction('branch', empty);
    await settle();
    expect(toast.current()?.message).toBe(translate('toast.nothingToBranch'));
  });

  it('renames through the dialog', async () => {
    render(<RenameDialog />);
    act(() => runChatMenuAction('rename', chat()));
    const field = screen.getByTestId('rename-dialog-field');
    expect(field.props.value).toBe(chat().title);
    fireEvent.changeText(field, 'From the menu');
    await act(async () => {
      fireEvent.press(screen.getByTestId('rename-dialog-save'));
    });
    expect(fresh().title).toBe('From the menu');
    expect(historyUi.renameDialogFor).toBeNull();
  });

  it('archives and leaves the chat', async () => {
    shellSession.open(chat().id);
    const id = chat().id;
    runChatMenuAction('archive', chat());
    await settle();
    expect(ports.conversations.get(id)?.archived).toBe(true);
    expect(shellSession.activeConversationId).toBeNull();
    expect(ports.conversations.archived().map(c => c.id)).toEqual([id]);
    runChatMenuAction('unarchive', ports.conversations.get(id)!);
    await settle();
    expect(ports.conversations.archived()).toHaveLength(0);
  });

  describe('lock', () => {
    it('locks only after the owner has been verified', async () => {
      unlockAnswer = 'cancelled';
      runChatMenuAction('lock', chat());
      await settle();
      expect(fresh().locked).toBe(false);

      unlockAnswer = 'ok';
      runChatMenuAction('lock', chat());
      await settle();
      expect(fresh().locked).toBe(true);
      // Whoever locked it keeps reading until the app is left.
      expect(lockState.isUnlocked(chat().id)).toBe(true);
      lockState.lockAll();
      expect(lockState.isUnlocked(chat().id)).toBe(false);
    });

    it('refuses on a phone without a screen lock', async () => {
      available = false;
      runChatMenuAction('lock', chat());
      await settle();
      expect(fresh().locked).toBe(false);
      expect(prompts).toBe(0);
      expect(toast.current()?.message).toBe(translate('lock.unavailable'));
    });

    it('shows a gate that opens only on a passing unlock', async () => {
      await ports.conversations.setLocked(chat().id, true);
      render(<LockedChatGate conversation={fresh()} />);
      unlockAnswer = 'cancelled';
      await act(async () => {
        fireEvent.press(screen.getByTestId('locked-gate-unlock'));
      });
      expect(lockState.isUnlocked(chat().id)).toBe(false);
      unlockAnswer = 'ok';
      await act(async () => {
        fireEvent.press(screen.getByTestId('locked-gate-unlock'));
      });
      expect(lockState.isUnlocked(chat().id)).toBe(true);
      expect(prompts).toBe(2);
    });

    it('removes the lock only for the owner', async () => {
      await ports.conversations.setLocked(chat().id, true);
      unlockAnswer = 'cancelled';
      runChatMenuAction('unlock', fresh());
      await settle();
      expect(fresh().locked).toBe(true);
      unlockAnswer = 'ok';
      runChatMenuAction('unlock', fresh());
      await settle();
      expect(fresh().locked).toBe(false);
    });
  });

  describe('temporary chat', () => {
    it('toggles on the new chat', () => {
      render(<TemporaryToggle />);
      const toggle = screen.getByTestId('temporary-toggle');
      expect(toggle.props.accessibilityState.checked).toBe(false);
      fireEvent.press(toggle);
      expect(shellSession.temporary).toBe(true);
      expect(
        screen.getByTestId('temporary-toggle').props.accessibilityState.checked,
      ).toBe(true);
    });

    it('leaves no row and no search hit, and is gone when left', async () => {
      const before = ports.conversations
        .sections()
        .flatMap(s => s.conversations).length;
      shellSession.setTemporary(true);
      await act(async () => {
        await sendFromShell('A plan about zebras');
      });
      const id = shellSession.activeConversationId!;
      expect(shellSession.temporary).toBe(true);
      expect(ports.conversations.get(id)?.temporary).toBe(true);
      expect(
        ports.conversations.sections().flatMap(s => s.conversations),
      ).toHaveLength(before);
      expect(await ports.conversations.search('zebras')).toHaveLength(0);

      act(() => shellSession.newChat());
      await settle();
      expect(ports.conversations.get(id)).toBeUndefined();
      expect(shellSession.temporary).toBe(false);
    });

    it('can be kept', async () => {
      shellSession.setTemporary(true);
      await act(async () => {
        await sendFromShell('Keep the zebras');
      });
      const id = shellSession.activeConversationId!;
      runChatMenuAction('save', ports.conversations.get(id)!);
      await settle();
      expect(ports.conversations.get(id)?.temporary).toBe(false);
      expect(shellSession.temporary).toBe(false);
      act(() => shellSession.newChat());
      await settle();
      expect(ports.conversations.get(id)).toBeTruthy();
    });

    it('is deleted at once from its menu, with nothing to undo', async () => {
      shellSession.setTemporary(true);
      await act(async () => {
        await sendFromShell('Short lived');
      });
      const id = shellSession.activeConversationId!;
      runChatMenuAction('delete', ports.conversations.get(id)!);
      await settle();
      expect(ports.conversations.get(id)).toBeUndefined();
      expect(historyUi.pendingDeleteIds.size).toBe(0);
    });

    it('does not make a normal chat temporary', async () => {
      await act(async () => {
        await sendFromShell('An ordinary question');
      });
      const id = shellSession.activeConversationId!;
      expect(ports.conversations.get(id)?.temporary).toBe(false);
      expect(shellSession.temporary).toBe(false);
    });
  });

  it('exports the fake thread in all three formats', async () => {
    const source = chat();
    ports.chat.seed(source.id, source.title);
    const markdown = await exportChat(source, 'markdown');
    expect(markdown.fileName.endsWith('.md')).toBe(true);
    expect(markdown.content.startsWith(`# ${source.title}`)).toBe(true);
    expect(markdown.content).toContain('**You**');

    const text = await exportChat(source, 'text');
    expect(text.content).toContain('You:\n');
    expect(text.content).not.toContain('**You**');

    const [conversation] = JSON.parse(
      (await exportChat(source, 'chatgpt')).content,
    );
    expect(conversation.title).toBe(source.title);
    const nodes = Object.values(conversation.mapping) as Array<{
      message: {author: {role: string}} | null;
    }>;
    expect(nodes.filter(node => node.message).length).toBe(
      ports.chat.messages(source.id).length,
    );
    expect(conversation.mapping[conversation.current_node]).toBeTruthy();
  });
});
