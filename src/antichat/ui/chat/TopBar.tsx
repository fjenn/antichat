import {ChatMenuButton} from '../chatmenu';
import React from 'react';
import {View} from 'react-native';
import Animated, {FadeIn, useReducedMotion} from 'react-native-reanimated';
import {StyleSheet} from 'react-native-unistyles';

import {getPorts, usePort} from '../../adapters';
import type {ConversationView, ModelView} from '../../contracts';
import {useT} from '../../locales';
import {
  ContextMenu,
  GlassSurface,
  Icon,
  IconButton,
  PressableScale,
  Text,
  type MenuItem,
} from '../primitives';
import {OfflinePill} from '../connectivity';
import {modelDescription, plainName} from '../models/ModelMenu';
import {isInstalled, roleOf} from '../models/naming';
import {useModels} from '../models/hooks';
import {modelCoordinator} from '../models/shared';
import {ms} from '../models/strings';
import {useUnrestrictedMode} from '../models/unrestrictedMode';
import type {Effort} from './chatUi';

export interface TopBarProps {
  conversation: ConversationView | undefined;
  /** A thread is on screen (even before its row exists in the list). */
  inChat: boolean;
  effort: Effort;
  /** The next chat will be an offline chat. */
  offlineNext: boolean;
  onOpenDrawer: () => void;
  onNewChat: () => void;
  onEffort: (effort: Effort) => void;
  onToggleOffline: () => void;
  onChatAction: (action: 'pin' | 'archive' | 'delete') => void;
  /** "Manage models" at the end of the menu. */
  onManageModels?: () => void;
}

/**
 * Floats over the conversation: the drawer button, the title (the app's name
 * with the model's plain label, "Smart" or "Fast"; the chat's name under it
 * once it has one) and the actions. A model's real name is never shown here:
 * it lives under Details in "Manage models".
 */
export function TopBar({
  conversation,
  inChat,
  effort,
  offlineNext,
  onOpenDrawer,
  onNewChat,
  onEffort,
  onToggleOffline,
  // The chat's own menu is M4's `ChatMenuButton` now; kept for callers.
  onChatAction: _onChatAction,
  onManageModels,
}: TopBarProps) {
  const t = useT();
  const reduceMotion = useReducedMotion();
  const {model} = getPorts();
  const {port, models: named, activeModelId} = useModels();
  const canThink = usePort(
    model,
    current => current.capabilities?.thinking.available ?? false,
  );
  // "Smart", "Fast"…; a model outside the line-up by its catalogue name.
  // Every model here comes from the catalogue, so none is "Custom".
  const unrestricted = useUnrestrictedMode();
  /** An unrestricted model is a mode of its standard one: same name. */
  const shown = (id: string): ModelView | undefined => {
    const view = port.models.find(item => item.id === id);
    const base = view?.baseModel
      ? port.models.find(item => item.id === view.baseModel)
      : undefined;
    return base && roleOf(base.id, named) !== 'other' ? base : view;
  };
  const plain = (id: string): string => {
    const view = shown(id);
    return view ? plainName(t, view, named) || t('model.custom') : '';
  };
  const installed = port.models.filter(
    item => item.supported && isInstalled(item),
  );
  const active = installed.find(item => item.id === activeModelId);
  const thinking = canThink && effort === 'think';
  const label = thinking
    ? t('model.think')
    : active
      ? plain(active.id)
      : undefined;
  const name = label ? `${t('app.name')} ${label}` : t('app.name');

  const items: MenuItem[] = [];
  if (canThink) {
    items.push({
      id: 'effort',
      title: t('model.effort'),
      inline: true,
      children: [
        {
          id: 'effort:fast',
          title: t('model.fast'),
          subtitle: t('model.fastHint'),
          checked: !thinking,
        },
        {
          id: 'effort:think',
          title: t('model.think'),
          subtitle: t('model.thinkHint'),
          checked: thinking,
        },
      ],
    });
  }
  // An unrestricted model whose standard one is here is reached through the
  // Unrestricted switch, not listed as a model of its own.
  const listed = installed.filter(
    item =>
      !item.baseModel || !installed.some(other => other.id === item.baseModel),
  );
  if (listed.length > 1) {
    items.push({
      id: 'models',
      title: t('model.models'),
      inline: true,
      children: listed.map(item => ({
        id: `model:${item.id}`,
        title: plain(item.id),
        subtitle: modelDescription(t, item, named),
        checked: item.id === activeModelId || item.id === active?.baseModel,
      })),
    });
  }
  if (unrestricted.item) {
    items.push({
      id: 'mode',
      title: '',
      inline: true,
      children: [unrestricted.item],
    });
  }
  if (onManageModels) {
    items.push({
      id: 'manage',
      title: t('models.menuManage'),
      icon: 'settings',
    });
  }

  const onMenu = (id: string) => {
    if (unrestricted.select(id)) {
      return;
    }
    if (id === 'effort:fast' || id === 'effort:think') {
      onEffort(id === 'effort:think' ? 'think' : 'fast');
    } else if (id === 'manage') {
      onManageModels?.();
    } else if (id.startsWith('model:')) {
      const modelId = id.slice('model:'.length);
      // Picking the app's own choice hands the choice back to the app.
      modelCoordinator().choose(modelId === named.smart?.id ? 'auto' : modelId);
    }
  };

  const title = conversation?.title;

  return (
    <View style={styles.bar} pointerEvents="box-none">
      <IconButton
        testID="open-drawer"
        icon="menu"
        variant="glass"
        accessibilityLabel={t('shell.openDrawer')}
        onPress={onOpenDrawer}
      />
      <ContextMenu items={items} onSelect={onMenu} style={styles.menu}>
        <PressableScale
          testID="model-menu"
          accessibilityRole="button"
          accessibilityLabel={
            title
              ? `${t('shell.modelMenu', {name})}. ${t('shell.chatTitle', {
                  title,
                })}`
              : t('shell.modelMenu', {name})
          }
          accessibilityHint={t('shell.modelMenuHint')}
          style={styles.title}>
          <View style={styles.titleLine}>
            <Text variant="headline" numberOfLines={1} style={styles.shrink}>
              {t('app.name')}
            </Text>
            {label ? (
              <Text
                testID="model-label"
                variant="headline"
                color="textTertiary"
                numberOfLines={1}>
                {label}
              </Text>
            ) : null}
            {unrestricted.on ? (
              <View
                testID="unrestricted-mode"
                accessibilityLabel={ms.modeLabel}>
                <Icon name="unlock" size={14} color="textTertiary" />
              </View>
            ) : null}
            <Icon name="chevronDown" size={16} color="textTertiary" />
          </View>
          {title ? (
            <Animated.View
              key={title}
              entering={reduceMotion ? undefined : FadeIn.duration(260)}>
              <Text
                testID="chat-title"
                variant="caption"
                color="textSecondary"
                numberOfLines={1}>
                {title}
              </Text>
            </Animated.View>
          ) : null}
        </PressableScale>
      </ContextMenu>
      {unrestricted.sheet}
      <OfflinePill style={styles.offline} />
      <GlassSurface style={styles.actions}>
        {inChat ? (
          <>
            <IconButton
              testID="new-chat"
              icon="newChat"
              accessibilityLabel={t('shell.newChat')}
              onPress={onNewChat}
            />
            {conversation ? (
              // M4's menu: rename, pin, share and export, lock, archive,
              // delete (and "save" for a temporary chat).
              <ChatMenuButton conversation={conversation} />
            ) : null}
          </>
        ) : (
          // Offline chat: where ChatGPT has its temporary-chat switch.
          <IconButton
            testID="offline-chat"
            icon="offline"
            accessibilityLabel={t(
              offlineNext ? 'shell.offlineOff' : 'shell.offlineOn',
            )}
            onPress={onToggleOffline}
            style={offlineNext ? styles.toggled : undefined}
          />
        )}
      </GlassSurface>
    </View>
  );
}

/** Height of the bar's buttons; the list starts its content under them. */
export const TOP_BAR_HEIGHT = 44;

const styles = StyleSheet.create((theme, rt) => ({
  bar: {
    position: 'absolute',
    top: rt.insets.top + theme.spacing.xs,
    left: 0,
    right: 0,
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.xs,
    paddingHorizontal: theme.spacing.lg,
  },
  menu: {
    flexShrink: 1,
  },
  title: {
    minHeight: theme.sizes.hitTarget,
    justifyContent: 'center',
    paddingHorizontal: theme.spacing.sm,
  },
  titleLine: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.xs,
  },
  shrink: {
    flexShrink: 1,
  },
  offline: {
    flexShrink: 0,
  },
  actions: {
    flexDirection: 'row',
    alignItems: 'center',
    marginStart: 'auto',
  },
  toggled: {
    borderRadius: theme.radii.pill,
    backgroundColor: theme.colors.accentSoft,
  },
}));
