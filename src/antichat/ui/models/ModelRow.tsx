import React from 'react';
import {View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import type {ModelView} from '../../contracts';
import {useT, type Translate} from '../../locales';
import {ProgressBar} from '../onboarding/ProgressBar';
import {RoundAction} from '../onboarding/RoundAction';
import {
  ContextMenu,
  Icon,
  IconButton,
  PressableScale,
  Text,
  type MenuItem,
} from '../primitives';
import {formatBytes, formatPercent, formatProgressBytes} from './format';
import {isMultilingual} from './languages';
import {fitOf, isArriving, isInstalled, type ModelRole} from './naming';
import {SwipeToDelete} from './SwipeToDelete';

export type ModelRowAction =
  | 'use'
  | 'download'
  | 'pause'
  | 'resume'
  | 'cancel'
  | 'retry'
  | 'delete'
  | 'details';

export interface ModelRowProps {
  model: ModelView;
  /** Plain name ("Smart"). */
  name: string;
  /** One line under the name ("Best for this phone"). */
  tagline: string;
  role: ModelRole;
  inUse: boolean;
  onAction: (action: ModelRowAction) => void;
  /** Store rows: a plain description under the name. */
  description?: string;
}

function stateLine(t: Translate, model: ModelView): string | null {
  const {state} = model;
  switch (state.status) {
    case 'downloading': {
      const percent = formatPercent(state.progress.fraction);
      if (!state.paused) {
        return t('models.state.downloading', {
          progress: formatProgressBytes(
            state.progress.receivedBytes,
            state.progress.totalBytes,
          ),
          percent,
        });
      }
      return state.pauseReason === 'offline'
        ? t('models.state.waiting', {percent})
        : t('models.state.paused', {percent});
    }
    case 'verifying':
      return t('models.state.verifying');
    case 'loading':
      return t('models.state.loading');
    case 'failed':
      return state.reason === 'storage_full'
        ? t('setup.failed.storageLineUnknown')
        : t('models.state.failed');
    default:
      return null;
  }
}

/**
 * One model in "Manage models": its plain name, one line about it, and the
 * one action that makes sense right now. Everything else is in the ••• menu.
 */
export function ModelRow({
  model,
  name,
  tagline,
  role,
  inUse,
  onAction,
  description,
}: ModelRowProps) {
  const t = useT();
  const {state} = model;
  const installed = isInstalled(model);
  const arriving = isArriving(model);
  const size = formatBytes(model.downloadBytes);
  const fit = fitOf(model);
  const tooLarge = fit === 'too_large' && !installed && !arriving;
  const fitLabel =
    fit === 'too_large' && installed
      ? t('models.fit.installedTooLarge')
      : fit === 'too_large'
        ? model.needsRamGb
          ? t('models.fit.tooLargeNeeds', {ram: model.needsRamGb})
          : t('models.fit.tooLarge')
        : t(`models.fit.${fit}`);
  const line =
    stateLine(t, model) ??
    (description !== undefined
      ? `${fitLabel} · ${size}`
      : `${tagline} · ${size}`);
  const failed = state.status === 'failed';
  const paused = state.status === 'downloading' && state.paused;
  const key = role === 'other' ? model.id : role;

  const menu: MenuItem[] = [];
  if (installed && !inUse) {
    menu.push({id: 'use', title: t('models.use'), icon: 'check'});
  }
  if (arriving) {
    menu.push({id: 'cancel', title: t('models.cancel'), destructive: true});
  }
  menu.push({id: 'details', title: t('models.details'), icon: 'info'});
  if (installed) {
    menu.push({
      id: 'delete',
      title: t('models.delete'),
      icon: 'delete',
      destructive: true,
    });
  }

  const trailing = () => {
    if (state.status === 'downloading') {
      return paused && state.pauseReason === 'offline' ? null : (
        <RoundAction
          testID={`model-${paused ? 'resume' : 'pause'}-${key}`}
          icon={paused ? 'play' : 'pause'}
          accessibilityLabel={`${paused ? t('models.resume') : t('models.pause')}, ${name}`}
          onPress={() => onAction(paused ? 'resume' : 'pause')}
        />
      );
    }
    if (failed) {
      return (
        <RoundAction
          testID={`model-retry-${key}`}
          icon="retry"
          accessibilityLabel={`${t('models.retry')}, ${name}`}
          onPress={() => onAction('retry')}
        />
      );
    }
    if (state.status === 'not_installed') {
      if (tooLarge) {
        return null;
      }
      return description !== undefined ? (
        <Pill
          testID={`model-download-${key}`}
          label={t('models.download')}
          accessibilityLabel={t('models.downloadLabel', {name, size})}
          onPress={() => onAction('download')}
        />
      ) : (
        <RoundAction
          testID={`model-download-${key}`}
          icon="download"
          accessibilityLabel={t('models.downloadLabel', {name, size})}
          onPress={() => onAction('download')}
        />
      );
    }
    if (installed && !inUse && model.supported && description !== undefined) {
      return (
        <Pill
          testID={`model-use-${key}`}
          label={t('models.use')}
          accessibilityLabel={`${t('models.use')}, ${name}`}
          onPress={() => onAction('use')}
        />
      );
    }
    return null;
  };

  const body = (
    <View style={[styles.row, tooLarge && styles.greyed]}>
      <PressableScale
        testID={`model-row-${key}`}
        accessibilityRole="button"
        accessibilityLabel={[
          name,
          inUse ? t('models.inUse') : null,
          description,
          line,
        ]
          .filter(Boolean)
          .join(', ')}
        accessibilityState={{selected: inUse}}
        scale={false}
        // Installed: tap to use it. Otherwise the row opens its Details.
        onPress={() =>
          onAction(installed && !inUse && model.supported ? 'use' : 'details')
        }
        style={styles.main}>
        <View style={styles.titleLine}>
          <Text variant="body" numberOfLines={1} style={styles.name}>
            {name}
          </Text>
          {inUse ? (
            <View testID={`model-in-use-${key}`} style={styles.inUse}>
              <Icon
                name="check"
                size={12}
                color="onAccentSoft"
                strokeWidth={3}
              />
              <Text variant="caption" color="onAccentSoft">
                {t('models.inUse')}
              </Text>
            </View>
          ) : null}
          {description !== undefined && isMultilingual(model.languages) ? (
            <View testID={`model-multilingual-${key}`} style={styles.tag}>
              <Text variant="caption" color="textSecondary">
                {t('models.multilingualTag')}
              </Text>
            </View>
          ) : null}
        </View>
        {description ? (
          <Text variant="footnote" color="textSecondary" numberOfLines={1}>
            {description}
          </Text>
        ) : null}
        <View style={styles.lineRow}>
          {description !== undefined && !stateLine(t, model) ? (
            <View
              style={[
                styles.dot,
                fit === 'great'
                  ? styles.dotGreat
                  : fit === 'ok' || installed
                    ? styles.dotOk
                    : styles.dotNo,
              ]}
            />
          ) : null}
          <Text
            testID={`model-line-${key}`}
            variant="footnote"
            color={
              failed
                ? 'danger'
                : description !== undefined
                  ? 'textPrimary'
                  : 'textSecondary'
            }
            style={styles.name}>
            {line}
          </Text>
        </View>
        {state.status === 'downloading' || state.status === 'verifying' ? (
          <View style={styles.bar}>
            <ProgressBar
              fraction={
                state.status === 'downloading'
                  ? state.progress.fraction
                  : state.fraction
              }
              idle={paused}
              accessibilityLabel={t('setup.progressLabel', {
                percent: formatPercent(
                  state.status === 'downloading'
                    ? state.progress.fraction
                    : state.fraction,
                ),
              })}
            />
          </View>
        ) : null}
      </PressableScale>
      {trailing()}
      {installed || arriving || description === undefined ? (
        // Secondary actions (delete, cancel) only where there are any.
        <ContextMenu
          items={menu}
          onSelect={id => onAction(id as ModelRowAction)}>
          <IconButton
            testID={`model-more-${key}`}
            icon="more"
            size={36}
            iconSize={18}
            accessibilityLabel={`${t('shell.moreActions')}, ${name}`}
          />
        </ContextMenu>
      ) : null}
    </View>
  );

  return (
    <SwipeToDelete
      enabled={installed}
      label={t('models.delete')}
      onDelete={() => onAction('delete')}>
      {body}
    </SwipeToDelete>
  );
}

/** The store's small text button: "Download", "Use". */
function Pill({
  label,
  accessibilityLabel,
  onPress,
  testID,
}: {
  label: string;
  accessibilityLabel: string;
  onPress: () => void;
  testID?: string;
}) {
  return (
    <PressableScale
      testID={testID}
      accessibilityRole="button"
      accessibilityLabel={accessibilityLabel}
      haptic
      hitSlop={8}
      onPress={onPress}
      style={styles.pill}>
      <Text variant="footnote" color="onAccentSoft" style={styles.pillText}>
        {label}
      </Text>
    </PressableScale>
  );
}

const styles = StyleSheet.create(theme => ({
  greyed: {
    opacity: 0.45,
  },
  lineRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.xs,
  },
  dot: {
    width: 7,
    height: 7,
    borderRadius: 4,
  },
  dotGreat: {
    backgroundColor: theme.colors.success,
  },
  dotOk: {
    backgroundColor: theme.colors.warning,
  },
  dotNo: {
    backgroundColor: theme.colors.textTertiary,
  },
  pill: {
    paddingHorizontal: theme.spacing.md,
    paddingVertical: theme.spacing.xs + 2,
    borderRadius: theme.radii.pill,
    backgroundColor: theme.colors.accentSoft,
  },
  pillText: {
    fontWeight: '600',
  },
  row: {
    minHeight: 64,
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.xs,
    paddingStart: theme.spacing.lg,
    paddingEnd: theme.spacing.md,
    paddingVertical: theme.spacing.sm,
  },
  main: {
    flex: 1,
    gap: theme.spacing.xxs,
    paddingVertical: theme.spacing.xs,
  },
  titleLine: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'center',
    columnGap: theme.spacing.sm,
    rowGap: theme.spacing.xxs,
  },
  name: {
    flexShrink: 1,
  },
  inUse: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.xs,
    paddingHorizontal: theme.spacing.sm,
    paddingVertical: 2,
    borderRadius: theme.radii.pill,
    backgroundColor: theme.colors.accentSoft,
  },
  tag: {
    paddingHorizontal: theme.spacing.sm,
    paddingVertical: 2,
    borderRadius: theme.radii.pill,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: theme.colors.border,
  },
  bar: {
    marginTop: theme.spacing.sm,
    marginBottom: theme.spacing.xxs,
  },
}));
