import React, {useEffect, useRef, useState} from 'react';
import {View} from 'react-native';
import {observer} from 'mobx-react';
import Animated, {
  FadeIn,
  FadeOut,
  LinearTransition,
  useReducedMotion,
} from 'react-native-reanimated';
import {StyleSheet} from 'react-native-unistyles';

import {useT} from '../../locales';
import {
  formatPercent,
  modelCoordinator,
  useSetupStatus,
  type SetupStatus,
} from '../models';
import {ModelDetailsSheet} from '../models/ModelDetailsSheet';
import {
  Button,
  Icon,
  PressableScale,
  Text,
  toast,
  type SheetHandle,
} from '../primitives';
import {
  notificationPermission,
  requestNotificationPermission,
} from './notifications';
import {CardButton} from './CardButton';
import {ProgressBar} from './ProgressBar';
import {RoundAction} from './RoundAction';
import {setupWording} from './wording';

export interface SetupCardProps {
  /** Opens Settings > Storage (the "not enough space" case). */
  onOpenStorage?: () => void;
}

/** Long enough that a notification is worth offering. */
const NOTIFY_MIN_SECONDS = 45;

/**
 * First run in one calm card: what is happening, how far it is, how long it
 * takes, and at most one thing to do about it. Shown on the chat screen
 * while there is no usable model; gone once there is.
 */
export const SetupCard = observer(function Setup({
  onOpenStorage,
}: SetupCardProps) {
  const t = useT();
  const status = useSetupStatus();
  const coordinator = modelCoordinator();
  const reduceMotion = useReducedMotion();
  const details = useRef<SheetHandle>(null);
  const canNotify = useCanNotify(status);

  if (status.kind === 'hidden') {
    return null;
  }
  const words = setupWording(t, status);
  const showBar = words.fraction !== undefined;
  const askNotify = async () => {
    coordinator.prefs.set({notifyAsked: true});
    const granted = await requestNotificationPermission();
    toast.show({
      message: t(granted ? 'setup.notifyOn' : 'setup.notifyDenied'),
      kind: granted ? 'success' : 'info',
      duration: granted ? 2200 : 4000,
    });
  };

  return (
    <Animated.View
      testID="setup-card"
      entering={reduceMotion ? undefined : FadeIn.duration(220)}
      exiting={reduceMotion ? undefined : FadeOut.duration(220)}
      layout={reduceMotion ? undefined : LinearTransition.duration(200)}
      style={styles.card}>
      <View style={styles.head}>
        {words.tone === 'success' ? (
          <Icon name="success" size={22} color="success" />
        ) : words.tone === 'problem' ? (
          <Icon name="warning" size={20} color="warning" />
        ) : null}
        <View style={styles.texts}>
          <Text
            testID="setup-title"
            variant="bodyStrong"
            accessibilityRole="header"
            accessibilityLiveRegion="polite">
            {words.title}
          </Text>
          <Text testID="setup-line" variant="footnote" color="textSecondary">
            {words.line}
          </Text>
        </View>
        <HeadAction status={status} />
      </View>

      {showBar ? (
        <ProgressBar
          testID="setup-progress"
          fraction={words.fraction ?? null}
          idle={words.idle}
          accessibilityLabel={t('setup.progressLabel', {
            percent: formatPercent(words.fraction ?? 0),
          })}
        />
      ) : null}

      <Actions status={status} onOpenStorage={onOpenStorage} />

      {status.kind !== 'ready' ? (
        <View style={styles.links}>
          <Link
            testID="setup-details"
            label={t('setup.details')}
            onPress={() => {
              details.current?.present().catch(() => {});
            }}
          />
          {canNotify ? (
            <Link
              testID="setup-notify"
              icon
              label={t('setup.notify')}
              onPress={() => {
                askNotify().catch(() => {});
              }}
            />
          ) : null}
        </View>
      ) : null}
      <ModelDetailsSheet ref={details} model={coordinator.target()} />
    </Animated.View>
  );
});

/** Offer the notification once, only while a long download is running. */
function useCanNotify(status: SetupStatus): boolean {
  const {prefs} = modelCoordinator();
  const [undetermined, setUndetermined] = useState(false);
  const downloading = status.kind === 'downloading';
  useEffect(() => {
    let live = true;
    if (downloading && !prefs.notifyAsked) {
      notificationPermission()
        .then(permission => {
          if (live) {
            setUndetermined(permission === 'undetermined');
          }
        })
        .catch(() => {});
    }
    return () => {
      live = false;
    };
  }, [downloading, prefs.notifyAsked]);
  return (
    status.kind === 'downloading' &&
    !prefs.notifyAsked &&
    undetermined &&
    (status.etaSeconds ?? 0) >= NOTIFY_MIN_SECONDS
  );
}

/** Pause or resume, at the end of the title row. */
function HeadAction({status}: {status: SetupStatus}) {
  const t = useT();
  const coordinator = modelCoordinator();
  if (status.kind === 'downloading') {
    return (
      <RoundAction
        testID="setup-pause"
        icon="pause"
        accessibilityLabel={t('setup.pause')}
        onPress={() => coordinator.pause()}
      />
    );
  }
  if (status.kind === 'paused' && status.reason === 'user') {
    return (
      <RoundAction
        testID="setup-resume"
        icon="play"
        accessibilityLabel={t('setup.resume')}
        onPress={() => coordinator.resume()}
      />
    );
  }
  return null;
}

/** The buttons of the states that need an answer. */
function Actions({
  status,
  onOpenStorage,
}: {
  status: SetupStatus;
  onOpenStorage?: () => void;
}) {
  const t = useT();
  const coordinator = modelCoordinator();
  switch (status.kind) {
    case 'confirm_metered':
      return (
        <View style={styles.buttons}>
          <CardButton
            testID="setup-wait-wifi"
            label={t('setup.waitForWifi')}
            style={styles.button}
            onPress={() => coordinator.waitForWifi()}
          />
          <Button
            testID="setup-use-data"
            label={t('setup.downloadNow')}
            style={styles.button}
            onPress={() => coordinator.useMobileData()}
          />
        </View>
      );
    case 'waiting_wifi':
      return (
        <View style={styles.buttons}>
          <CardButton
            testID="setup-use-data"
            label={t('setup.useMobileData')}
            style={styles.button}
            onPress={() => coordinator.useMobileData()}
          />
        </View>
      );
    case 'paused':
      return status.reason === 'metered' ? (
        <View style={styles.buttons}>
          <CardButton
            testID="setup-use-data"
            label={t('setup.continueMetered')}
            style={styles.button}
            onPress={() => coordinator.useMobileData()}
          />
        </View>
      ) : null;
    case 'missing':
      return (
        <View style={styles.buttons}>
          <Button
            testID="setup-download"
            label={t('setup.download')}
            icon="download"
            style={styles.button}
            onPress={() => coordinator.resume()}
          />
        </View>
      );
    case 'failed':
      return (
        <View style={styles.buttons}>
          {status.reason === 'storage_full' && onOpenStorage ? (
            <CardButton
              testID="setup-storage"
              label={t('setup.failed.openStorage')}
              style={styles.button}
              onPress={onOpenStorage}
            />
          ) : null}
          <Button
            testID="setup-retry"
            label={
              status.reason === 'checksum_mismatch' ||
              status.reason === 'file_missing'
                ? t('setup.failed.downloadAgain')
                : t('common.retry')
            }
            icon="retry"
            style={styles.button}
            onPress={() => coordinator.retry()}
          />
        </View>
      );
    default:
      return null;
  }
}

function Link({
  label,
  icon = false,
  onPress,
  testID,
}: {
  label: string;
  icon?: boolean;
  onPress: () => void;
  testID?: string;
}) {
  return (
    <PressableScale
      testID={testID}
      accessibilityRole="button"
      accessibilityLabel={label}
      hitSlop={12}
      onPress={onPress}
      style={styles.link}>
      {icon ? <Icon name="bell" size={14} color="textSecondary" /> : null}
      <Text variant="footnote" color="textSecondary" style={styles.linkText}>
        {label}
      </Text>
    </PressableScale>
  );
}

const styles = StyleSheet.create(theme => ({
  card: {
    gap: theme.spacing.md,
    paddingHorizontal: theme.spacing.lg,
    paddingVertical: theme.spacing.lg,
    borderRadius: theme.radii.xl,
    borderCurve: 'continuous',
    backgroundColor: theme.colors.surface,
  },
  head: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.md,
  },
  texts: {
    flex: 1,
    gap: theme.spacing.xxs,
  },
  buttons: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: theme.spacing.sm,
  },
  button: {
    flexGrow: 1,
    alignSelf: 'auto',
  },
  links: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    justifyContent: 'space-between',
    columnGap: theme.spacing.lg,
    rowGap: theme.spacing.sm,
  },
  link: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.xs,
  },
  linkText: {
    textDecorationLine: 'underline',
  },
}));
