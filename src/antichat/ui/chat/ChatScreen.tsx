/**
 * The chat screen: one conversation (or the empty chat the app opens into),
 * the floating top bar, the composer, and the sheets that belong to a
 * message. Everything it knows about the model and the history comes
 * through the ports.
 */
import React, {useCallback, useEffect, useMemo, useRef} from 'react';
import {Share, View} from 'react-native';
import Clipboard from '@react-native-clipboard/clipboard';
import {DrawerActions, useNavigation} from '@react-navigation/native';
import {observer} from 'mobx-react';
import {KeyboardController} from 'react-native-keyboard-controller';
import {useSharedValue, type SharedValue} from 'react-native-reanimated';
import {StyleSheet, useUnistyles} from 'react-native-unistyles';

import {getPorts} from '../../adapters';
import type {
  ChatMessageView,
  ChatPort,
  ConversationView,
  SendInput,
  Starter,
} from '../../contracts';
import {FakeChat} from '../../contracts/fakes';
import {useT} from '../../locales';
import {shellSession} from '../../app/session';
import {isDevBuild} from '../../spike-ui/launch';
import {Composer, type ComposerHandle} from '../composer/Composer';
import {EdgeFade, haptics, toast} from '../primitives';
import {AutoRunner} from './AutoRunner';
import {offlineChats} from '../../engine/offline';
import {chatUi, type EditTarget} from './chatUi';
import {threadDebug} from './debug';
import {Greeting, Starters} from './EmptyState';
import {plainText} from './format';
import {ReasoningSheet} from './ReasoningSheet';
import {SelectTextSheet} from './SelectTextSheet';
import {ThreadActionsContext, type ThreadActions} from './thread/actions';
import {ThreadList, type ThreadListHandle} from './thread/ThreadList';
import {useThread} from './thread/useThread';
import {LockedChatGate, lockState} from '../chatmenu';
import {registerVoiceUi} from '../voice';
import {MemoryUpdatedNotice} from '../memory';
import {openMemoryScreen} from '../../app/navigate';
import {ModelNotices, SetupCard, useComposerReadiness} from '../onboarding';
import {TOP_BAR_HEIGHT, TopBar} from './TopBar';
import {usePortValue} from './usePortValue';

export const ChatScreen = observer(function Chat() {
  const t = useT();
  const navigation = useNavigation();
  const {theme, rt} = useUnistyles();
  const ports = getPorts();
  const conversationId = shellSession.activeConversationId;
  const readiness = useComposerReadiness();
  const composer = useRef<ComposerHandle>(null);
  // M11: dictated text lands in the composer.
  useEffect(
    () =>
      registerVoiceUi({
        insertText: text => composer.current?.insertText(text),
      }),
    [],
  );
  const composerHeight = useSharedValue(
    theme.sizes.composerMinHeight + theme.spacing.sm + rt.insets.bottom,
  );
  // A new chat starts without the last chat's tool chips (Search).
  useEffect(() => {
    if (!conversationId) {
      ports.tools.clearActive(null);
    }
  }, [conversationId, ports.tools]);
  const barTop = rt.insets.top + theme.spacing.xs;
  const topInset = barTop + TOP_BAR_HEIGHT + theme.spacing.sm;

  const generating = usePortValue(
    ports.chat,
    chat => !!conversationId && chat.isGenerating(conversationId),
  );
  const title = usePortValue(ports.conversations, list =>
    conversationId ? (list.get(conversationId)?.title ?? null) : null,
  );
  const pinned = usePortValue(
    ports.conversations,
    list => !!conversationId && !!list.get(conversationId)?.pinned,
  );
  const temporary = usePortValue(
    ports.conversations,
    list => !!conversationId && !!list.get(conversationId)?.temporary,
  );
  const offline = offlineChats.has(conversationId);
  const conversation = useMemo<ConversationView | undefined>(
    () =>
      conversationId && title !== null
        ? ports.conversations.get(conversationId)
        : undefined,
    // `pinned` is read through the port; it is here to refresh the object.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [conversationId, title, pinned, ports.conversations],
  );

  useEffect(() => {
    chatUi.load().catch(() => {});
    threadDebug.composer = composer.current;
  }, []);

  useEffect(() => {
    chatUi.resetForConversation();
  }, [conversationId]);

  // History rows of the fake backend have no thread until they are opened.
  useEffect(() => {
    if (
      conversationId &&
      title &&
      ports.chat instanceof FakeChat &&
      ports.chat.messages(conversationId).length === 0
    ) {
      ports.chat.seed(conversationId, title);
    }
  }, [title, conversationId, ports.chat]);

  const send = useCallback(
    async (input: SendInput) => {
      // The answer gets the screen; the keyboard comes back when asked for.
      KeyboardController.dismiss().catch(() => {});
      try {
        const target = shellSession.activeConversationId;
        // A new offline chat: its id comes with the first message, and the
        // request seam claims it before anything is sent.
        const startOffline = !target && chatUi.offlineNext;
        if (startOffline) {
          offlineChats.arm();
        }
        let result;
        try {
          result = await ports.chat.send(target, input);
          if (startOffline && result.conversationId) {
            offlineChats.mark(result.conversationId);
          }
        } finally {
          if (startOffline) {
            offlineChats.disarm();
          }
        }
        chatUi.setOfflineNext(false);
        if (shellSession.activeConversationId !== result.conversationId) {
          shellSession.open(result.conversationId);
        }
      } catch {
        // Nothing was sent: the words go back into the field.
        composer.current?.setText(input.text);
        toast.show({message: t('errors.send'), kind: 'error'});
      }
    },
    [ports, t],
  );

  const onStarter = useCallback(
    (starter: Starter) => {
      haptics.tap();
      send({text: starter.prompt, thinking: chatUi.effort === 'think'}).catch(
        () => {},
      );
    },
    [send],
  );

  const onEdit = useCallback(
    (target: EditTarget, text: string) => {
      ports.chat
        .edit(target.conversationId, target.messageId, {
          text,
          thinking: chatUi.effort === 'think',
        })
        .catch(() => toast.show({message: t('errors.send'), kind: 'error'}));
    },
    [ports, t],
  );

  const onStop = useCallback(() => {
    const id = shellSession.activeConversationId;
    if (id) {
      ports.chat.stop(id);
    }
  }, [ports]);

  const onChatAction = (action: 'pin' | 'archive' | 'delete') => {
    if (!conversation) {
      return;
    }
    const failed = () =>
      toast.show({message: t('errors.generic'), kind: 'error'});
    switch (action) {
      case 'pin':
        ports.conversations
          .setPinned(conversation.id, !conversation.pinned)
          .catch(failed);
        toast.show({
          message: t(
            conversation.pinned ? 'toast.chatUnpinned' : 'toast.chatPinned',
          ),
        });
        break;
      case 'archive':
        ports.conversations.setArchived(conversation.id, true).catch(failed);
        shellSession.newChat();
        toast.show({message: t('toast.chatArchived')});
        break;
      case 'delete':
        ports.conversations.remove(conversation.id).catch(failed);
        shellSession.newChat();
        toast.show({message: t('toast.chatDeleted')});
        break;
    }
  };

  return (
    <View testID="chat-shell" style={styles.screen}>
      {conversationId &&
      conversation?.locked &&
      !lockState.isUnlocked(conversationId) ? (
        // M4: a locked chat shows nothing until the device unlock succeeds.
        <LockedChatGate conversation={conversation} />
      ) : conversationId ? (
        <OpenThread
          key={conversationId}
          chat={ports.chat}
          conversationId={conversationId}
          composerHeight={composerHeight}
          topInset={topInset}
          onSend={send}
        />
      ) : (
        <View style={styles.empty(topInset)}>
          <Greeting offline={chatUi.offlineNext} />
          {/* M6: first run (the one download card) and engine notices. */}
          <View style={styles.setup}>
            <ModelNotices />
            <SetupCard
              onOpenStorage={() =>
                (navigation as any).navigate('Main', {screen: 'Storage'})
              }
            />
          </View>
        </View>
      )}

      {/* Opaque behind the title, which has no glass of its own; clear
          again where a pinned question sits. */}
      <EdgeFade
        edge="top"
        height={topInset + theme.spacing.xs}
        solid={barTop + TOP_BAR_HEIGHT}
      />

      <TopBar
        conversation={conversation}
        inChat={!!conversationId}
        effort={chatUi.effort}
        offlineNext={chatUi.offlineNext}
        onOpenDrawer={() => navigation.dispatch(DrawerActions.openDrawer())}
        onNewChat={() => {
          chatUi.setOfflineNext(false);
          shellSession.newChat();
        }}
        onEffort={chatUi.setEffort}
        onToggleOffline={() => {
          haptics.selection();
          chatUi.setOfflineNext(!chatUi.offlineNext);
        }}
        onChatAction={onChatAction}
        onManageModels={() =>
          (navigation.navigate as (name: string, params: object) => void)(
            'Main',
            {screen: 'Models'},
          )
        }
      />

      {isDevBuild() ? <AutoRunner /> : null}

      <Composer
        ref={composer}
        conversationId={conversationId}
        generating={generating}
        temporary={!!conversationId && temporary}
        offline={conversationId ? offline : chatUi.offlineNext}
        onSend={input => {
          send(input).catch(() => {});
        }}
        onEdit={onEdit}
        onStop={onStop}
        height={composerHeight}
        above={
          conversationId ? (
            // M9: "Memory updated", with undo and the way to manage.
            <MemoryUpdatedNotice
              conversationId={conversationId}
              onManage={openMemoryScreen}
            />
          ) : readiness.ready ? (
            // M6: starters wait for a loaded model.
            <Starters starters={ports.chat.starters()} onStarter={onStarter} />
          ) : null
        }
      />
    </View>
  );
});

interface OpenThreadProps {
  chat: ChatPort;
  conversationId: string;
  composerHeight: SharedValue<number>;
  topInset: number;
  onSend: (input: SendInput) => Promise<void>;
}

/** One conversation: its controller, its list, and the message sheets. */
const OpenThread = observer(function Open({
  chat,
  conversationId,
  composerHeight,
  topInset,
  onSend,
}: OpenThreadProps) {
  const t = useT();
  const ports = getPorts();
  const {controller, snapshot} = useThread(chat, conversationId);
  const list = useRef<ThreadListHandle>(null);

  useEffect(() => {
    threadDebug.current = list.current;
    threadDebug.controller = controller;
    return () => {
      threadDebug.current = null;
      threadDebug.controller = null;
    };
  }, [controller]);

  const actions = useMemo<ThreadActions>(() => {
    const options = () => ({thinking: chatUi.effort === 'think'});
    const failed = () =>
      toast.show({message: t('errors.generic'), kind: 'error'});
    const regenerate = (message: ChatMessageView) => {
      haptics.tap();
      chat.regenerate(conversationId, message.id, options()).catch(failed);
    };
    return {
      copy: (message, quiet) => {
        Clipboard.setString(plainText(message.text));
        if (!quiet) {
          toast.show({message: t('thread.copied')});
        }
      },
      share: message => {
        Share.share({message: plainText(message.text)}).catch(() => {});
      },
      readAloud: message => {
        const {voice} = ports;
        if (
          voice.speech.status !== 'idle' &&
          voice.speech.messageId === message.id
        ) {
          voice.stopSpeech();
        } else {
          voice.speak(message.id, plainText(message.text)).catch(failed);
        }
      },
      setFeedback: (message, feedback) => {
        chat.setFeedback(conversationId, message.id, feedback).catch(failed);
      },
      regenerate,
      retry: regenerate,
      edit: message =>
        chatUi.startEdit({
          conversationId,
          messageId: message.id,
          text: message.text,
        }),
      branch: message => {
        ports.conversations
          .branch(conversationId, message.id)
          .then(branched => {
            shellSession.open(branched.id);
            toast.show({message: t('thread.branched')});
          })
          .catch(() =>
            toast.show({message: t('errors.branch'), kind: 'error'}),
          );
      },
      selectText: message => {
        KeyboardController.dismiss().catch(() => {});
        chatUi.selectText(message);
      },
      switchVersion: (message, index) => {
        chat.switchVersion(conversationId, message.id, index).catch(() =>
          toast.show({
            message: t('errors.switchWhileWriting'),
            kind: 'error',
          }),
        );
      },
      openReasoning: message => {
        KeyboardController.dismiss().catch(() => {});
        chatUi.showReasoning(message.id);
      },
      followUp: text => {
        onSend({text, ...options()}).catch(() => {});
      },
    };
  }, [chat, conversationId, onSend, ports, t]);

  return (
    <ThreadActionsContext.Provider value={actions}>
      <ThreadList
        ref={list}
        snapshot={snapshot}
        composerHeight={composerHeight}
        topInset={topInset}
      />
      <ReasoningSheet
        controller={controller}
        messageId={chatUi.reasoningFor}
        onClose={() => chatUi.showReasoning(null)}
      />
      <SelectTextSheet
        message={chatUi.selecting}
        onClose={() => chatUi.selectText(null)}
        onAsk={chatUi.setQuote}
      />
    </ThreadActionsContext.Provider>
  );
});

const styles = StyleSheet.create((theme, rt) => ({
  screen: {
    flex: 1,
    backgroundColor: theme.colors.background,
  },
  setup: {
    paddingHorizontal: theme.spacing.lg,
    gap: theme.spacing.sm,
    alignItems: 'stretch',
  },
  empty: (topInset: number) => ({
    flex: 1,
    paddingTop: topInset,
    // Roughly where the composer and the starters are.
    paddingBottom: rt.insets.bottom + 160,
  }),
}));
