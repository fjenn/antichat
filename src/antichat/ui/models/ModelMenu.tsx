import React from 'react';
import type {StyleProp, ViewStyle} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {getPorts, usePort} from '../../adapters';
import {useT, type Translate} from '../../locales';
import {
  ContextMenu,
  Icon,
  PressableScale,
  Text,
  haptics,
  type MenuItem,
} from '../primitives';
import {useModels} from './hooks';
import {isInstalled, roleOf, type ModelLineup, type ModelRole} from './naming';
import {modelCoordinator} from './shared';
import type {ModelView} from '../../contracts';

const MODEL_PREFIX = 'model:';
const THINK = 'think';
const MANAGE = 'manage';

/** "Smart", "Fast"…; a model outside the line-up keeps its own name. */
export function plainName(
  t: Translate,
  model: ModelView,
  models: ModelLineup,
): string {
  const role = roleOf(model.id, models);
  return role === 'other' ? model.displayName : t(`models.name.${role}`);
}

export function tagline(t: Translate, role: ModelRole): string {
  return t(`models.tagline.${role}`);
}

/** One line under a model's name: its role's line, else the catalogue's. */
export function modelDescription(
  t: Translate,
  model: ModelView,
  models: ModelLineup,
): string {
  const role = roleOf(model.id, models);
  return role === 'other' && model.summary ? model.summary : tagline(t, role);
}

export interface ModelMenuState {
  /** What the top bar shows: "AntiChat", or "AntiChat Fast". */
  title: string;
  items: MenuItem[];
  onSelect: (id: string) => void;
}

/**
 * Contents of the top-bar menu: the installed models by plain name (when
 * there is a choice), "Think longer" where the model has it, and "Manage
 * models". M2's chat screen can draw its own button around this.
 */
export function useModelMenu(onManage: () => void): ModelMenuState {
  const t = useT();
  const {port, models, activeModelId} = useModels();
  const capabilities = usePort(
    getPorts().model,
    current => current.capabilities,
  );
  const coordinator = modelCoordinator();
  const {prefs} = coordinator;

  const installed = port.models.filter(
    model => model.supported && isInstalled(model),
  );
  const active = installed.find(model => model.id === activeModelId);
  const activeRole = active ? roleOf(active.id, models) : 'smart';
  const title =
    !active || activeRole === 'smart'
      ? t('app.name')
      : t('models.titleSuffix', {name: plainName(t, active, models)});

  const items: MenuItem[] = [];
  if (installed.length > 1) {
    installed.forEach(model => {
      items.push({
        id: `${MODEL_PREFIX}${model.id}`,
        title: plainName(t, model, models),
        subtitle: tagline(t, roleOf(model.id, models)),
        checked: model.id === activeModelId,
      });
    });
  }
  const canThink =
    active !== undefined &&
    capabilities?.thinking.available === true &&
    !capabilities.thinkingAlwaysOn;
  if (canThink) {
    items.push({
      id: THINK,
      title: t('models.menuThink'),
      subtitle: t('models.menuThinkHint'),
      icon: 'think',
      checked: prefs.thinking,
    });
  }
  items.push({id: MANAGE, title: t('models.menuManage'), icon: 'settings'});

  const onSelect = (id: string) => {
    if (id === MANAGE) {
      onManage();
    } else if (id === THINK) {
      haptics.selection();
      prefs.set({thinking: !prefs.thinking});
    } else if (id.startsWith(MODEL_PREFIX)) {
      const modelId = id.slice(MODEL_PREFIX.length);
      // Picking the app's own choice hands the choice back to the app.
      coordinator.choose(modelId === models.smart?.id ? 'auto' : modelId);
    }
  };
  return {title, items, onSelect};
}

export interface ModelMenuButtonProps {
  onManage: () => void;
  style?: StyleProp<ViewStyle>;
}

/** The top-bar title with its menu, as the M1 shell draws it. */
export function ModelMenuButton({onManage, style}: ModelMenuButtonProps) {
  const t = useT();
  const {title, items, onSelect} = useModelMenu(onManage);
  return (
    <ContextMenu items={items} onSelect={onSelect} style={style}>
      <PressableScale
        testID="model-menu"
        accessibilityRole="button"
        accessibilityLabel={t('shell.modelMenu', {name: title})}
        accessibilityHint={t('shell.modelMenuHint')}
        style={styles.button}>
        <Text variant="headline" numberOfLines={1} style={styles.name}>
          {title}
        </Text>
        <Icon name="chevronDown" size={16} color="textTertiary" />
      </PressableScale>
    </ContextMenu>
  );
}

const styles = StyleSheet.create(theme => ({
  button: {
    minHeight: theme.sizes.hitTarget,
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.xs,
    paddingHorizontal: theme.spacing.sm,
  },
  name: {
    flexShrink: 1,
  },
}));
