import React from 'react';
import {View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {getPorts, usePort} from '../../adapters';
import type {ModelNotice} from '../../contracts';
import {useT, type Translate} from '../../locales';
import {formatBytes} from '../models';
import {Button, Icon, IconButton, Text} from '../primitives';
import {CardButton} from './CardButton';

/**
 * Things the engine wants the user to know, shown as quiet lines where they
 * are (never an alert): a smaller model was used, memory ran low, or answers
 * are slow and a faster model is on offer.
 */
export function ModelNotices() {
  const t = useT();
  const port = getPorts().model;
  const notices = usePort(port, current => current.notices);
  const shown = notices.filter(notice => notice.kind !== 'confirm_metered');
  if (shown.length === 0) {
    return null;
  }
  return (
    <View style={styles.stack}>
      {shown.map(notice =>
        notice.kind === 'slow_offer_smaller' ? (
          <View key={notice.id} testID="notice-slow" style={styles.card}>
            <View style={styles.texts}>
              <Text variant="calloutStrong">{t('setup.notice.slowTitle')}</Text>
              <Text variant="footnote" color="textSecondary">
                {t('setup.notice.slowLine')}
              </Text>
            </View>
            <View style={styles.buttons}>
              <CardButton
                label={t('setup.notice.slowKeep')}
                style={styles.button}
                onPress={() => {
                  port.answerNotice(notice.id, false).catch(() => {});
                }}
              />
              <Button
                label={t('setup.notice.slowSwitch')}
                style={styles.button}
                onPress={() => {
                  port.answerNotice(notice.id, true).catch(() => {});
                }}
              />
            </View>
          </View>
        ) : (
          <View
            key={notice.id}
            testID={`notice-${notice.kind}`}
            style={styles.line}>
            <Icon name="info" size={16} color="textSecondary" />
            <Text
              variant="footnote"
              color="textSecondary"
              accessibilityLiveRegion="polite"
              style={styles.grow}>
              {noticeText(t, notice)}
            </Text>
            <IconButton
              icon="close"
              size={28}
              iconSize={14}
              accessibilityLabel={t('setup.notice.dismiss')}
              onPress={() => port.dismissNotice(notice.id)}
            />
          </View>
        ),
      )}
    </View>
  );
}

function noticeText(t: Translate, notice: ModelNotice): string {
  switch (notice.kind) {
    case 'storage_limited':
      return t('setup.notice.storageLimited', {
        size: formatBytes(Math.max(0, notice.neededBytes - notice.freeBytes)),
      });
    case 'low_memory_switched':
      return t('setup.notice.lowMemory');
    case 'load_fell_back':
      return t('setup.notice.fellBack');
    default:
      return '';
  }
}

const styles = StyleSheet.create(theme => ({
  stack: {
    gap: theme.spacing.sm,
  },
  card: {
    gap: theme.spacing.md,
    padding: theme.spacing.lg,
    borderRadius: theme.radii.xl,
    borderCurve: 'continuous',
    backgroundColor: theme.colors.surface,
  },
  texts: {
    gap: theme.spacing.xxs,
  },
  buttons: {
    flexDirection: 'row',
    gap: theme.spacing.sm,
  },
  button: {
    flexGrow: 1,
    alignSelf: 'auto',
  },
  line: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.sm,
    paddingStart: theme.spacing.lg,
    paddingEnd: theme.spacing.xs,
  },
  grow: {
    flex: 1,
  },
}));
