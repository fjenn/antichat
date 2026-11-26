import React from 'react';
import {ActivityIndicator, View} from 'react-native';
import {StyleSheet, useUnistyles} from 'react-native-unistyles';

import type {ModelView} from '../../contracts';
import {useT} from '../../locales';
import {fitOf, formatBytes, isInstalled, phoneName} from '../models';
import {Button, Icon, PressableScale, Text} from '../primitives';

export interface PickScreenProps {
  /** The app's pick for this phone; undefined while the phone is checked. */
  model?: ModelView;
  /** Plain name of the pick ("Smart"). */
  name?: string;
  offline?: boolean;
  onDownload: () => void;
  /** Opens the model store instead. */
  onOther: () => void;
}

/**
 * First run, after "Get started": the one model this phone should run, as a
 * single card, and one button. Other models are one quiet link away.
 */
export function PickScreen({
  model,
  name,
  offline = false,
  onDownload,
  onOther,
}: PickScreenProps) {
  const t = useT();
  const {theme} = useUnistyles();
  const device = phoneName();
  const speed =
    model && fitOf(model) === 'great'
      ? t('pick.speedGreat')
      : t('pick.speedOk');
  const size = model ? formatBytes(model.downloadBytes) : '';
  const line = device
    ? t('pick.lineDevice', {device, size, speed})
    : t('pick.lineGeneric', {size, speed});

  return (
    <View testID="pick" style={styles.screen}>
      <View style={styles.hero}>
        <Text
          variant="largeTitle"
          align="center"
          accessibilityRole="header"
          style={styles.title}>
          {t('pick.title')}
        </Text>
        <Text color="textSecondary" align="center" style={styles.subtitle}>
          {t('pick.subtitle')}
        </Text>
        <View testID="pick-card" style={styles.card}>
          {model ? (
            <>
              <View style={styles.badge}>
                <Icon name="sparkles" size={22} color="onAccentSoft" />
              </View>
              <Text
                testID="pick-name"
                variant="title"
                align="center"
                style={styles.name}>
                {name ?? model.displayName}
              </Text>
              <Text
                testID="pick-line"
                variant="footnote"
                color="textSecondary"
                align="center">
                {line}
              </Text>
              {model.summary ? (
                <Text variant="footnote" color="textTertiary" align="center">
                  {model.summary}
                </Text>
              ) : null}
            </>
          ) : (
            <View style={styles.checking}>
              <ActivityIndicator color={theme.colors.textSecondary} />
              <Text variant="footnote" color="textSecondary">
                {t('pick.checking')}
              </Text>
            </View>
          )}
        </View>
      </View>
      <View style={styles.footer}>
        {offline ? (
          <View style={styles.offline}>
            <Icon name="offline" size={16} color="textSecondary" />
            <Text variant="footnote" color="textSecondary" style={styles.grow}>
              {t('pick.offline')}
            </Text>
          </View>
        ) : null}
        <Button
          testID="pick-download"
          label={
            model && isInstalled(model)
              ? t('pick.start')
              : model
                ? `${t('pick.download')} · ${size}`
                : t('pick.download')
          }
          icon={model && isInstalled(model) ? undefined : 'download'}
          accessibilityHint={t('pick.downloadHint')}
          size="lg"
          fullWidth
          disabled={!model}
          onPress={onDownload}
        />
        <PressableScale
          testID="pick-other"
          accessibilityRole="button"
          accessibilityLabel={t('pick.other')}
          hitSlop={12}
          onPress={onOther}
          style={styles.other}>
          <Text variant="footnote" color="textSecondary">
            {t('pick.other')}
          </Text>
        </PressableScale>
      </View>
    </View>
  );
}

const styles = StyleSheet.create((theme, rt) => ({
  screen: {
    flex: 1,
    backgroundColor: theme.colors.background,
    paddingTop: rt.insets.top,
    paddingBottom:
      Math.max(rt.insets.bottom, theme.spacing.lg) + theme.spacing.sm,
    paddingHorizontal: theme.spacing.xxl,
  },
  hero: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    gap: theme.spacing.md,
  },
  title: {
    fontSize: 30,
    lineHeight: 36,
    letterSpacing: -0.6,
  },
  subtitle: {
    maxWidth: 300,
  },
  card: {
    alignSelf: 'stretch',
    alignItems: 'center',
    gap: theme.spacing.sm,
    marginTop: theme.spacing.xl,
    paddingHorizontal: theme.spacing.lg,
    paddingVertical: theme.spacing.xl,
    minHeight: 168,
    justifyContent: 'center',
    borderRadius: theme.radii.xl,
    borderCurve: 'continuous',
    backgroundColor: theme.colors.surface,
  },
  badge: {
    width: 48,
    height: 48,
    borderRadius: 24,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: theme.colors.accentSoft,
    marginBottom: theme.spacing.xs,
  },
  name: {
    fontSize: 24,
    lineHeight: 30,
  },
  checking: {
    alignItems: 'center',
    gap: theme.spacing.sm,
  },
  footer: {
    gap: theme.spacing.md,
  },
  offline: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.sm,
    paddingHorizontal: theme.spacing.xs,
  },
  grow: {
    flex: 1,
  },
  other: {
    alignSelf: 'center',
    paddingVertical: theme.spacing.xs,
  },
}));
