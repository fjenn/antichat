import React, {useCallback, useEffect, useMemo, useRef} from 'react';
import {I18nManager, View} from 'react-native';
import {Gesture, GestureDetector} from 'react-native-gesture-handler';
import Animated, {
  interpolate,
  runOnJS,
  useAnimatedStyle,
  useReducedMotion,
  useSharedValue,
  withSpring,
  withTiming,
  type SharedValue,
} from 'react-native-reanimated';
import {StyleSheet} from 'react-native-unistyles';

import {motion} from '../../theme';
import {Icon, PressableScale, haptics, type IconName} from '../primitives';

export interface SwipeAction {
  id: string;
  label: string;
  icon: IconName;
  destructive?: boolean;
}

export interface SwipeActionsProps {
  actions: readonly SwipeAction[];
  onAction: (id: string) => void;
  enabled?: boolean;
  children: React.ReactNode;
  testID?: string;
}

/** Width of one revealed button, the gap between buttons, the end inset. */
const ACTION_WIDTH = 52;
const ACTION_GAP = 6;
const END_INSET = 4;
/** A flick this fast (points per second) opens or closes on its own. */
const FLICK = 500;

interface OpenRow {
  close: () => void;
}

// Only one row shows its actions at a time, as in every list that has them.
let openRow: OpenRow | null = null;

/**
 * Closes the row that shows its actions (on scroll, on drawer close, before
 * another row is used). Returns whether there was one.
 */
export function closeOpenSwipeRow(): boolean {
  if (!openRow) {
    return false;
  }
  openRow.close();
  openRow = null;
  return true;
}

/**
 * A row that slides towards the start edge to show its actions at the end.
 * The actions are buttons to tap; a long swipe never fires one by itself.
 *
 * Built on Gesture Handler's pan directly. Its `ReanimatedSwipeable` (3.5)
 * did not respond inside our lists on Android.
 */
export function SwipeActions({
  actions,
  onAction,
  enabled = true,
  children,
  testID,
}: SwipeActionsProps) {
  const reduceMotion = useReducedMotion();
  const width =
    actions.length * ACTION_WIDTH +
    Math.max(0, actions.length - 1) * ACTION_GAP +
    ACTION_GAP +
    END_INSET;
  // Rows slide towards the start: left normally, right in RTL layouts.
  const direction = I18nManager.isRTL ? 1 : -1;
  /** 0 closed … 1 fully open. */
  const progress = useSharedValue(0);
  const startProgress = useSharedValue(0);
  const self = useRef<OpenRow | null>(null);

  const settle = useCallback(
    (open: boolean) => {
      'worklet';
      progress.value = reduceMotion
        ? withTiming(open ? 1 : 0, {duration: motion.duration.fast})
        : withSpring(open ? 1 : 0, motion.spring.snappy);
    },
    [progress, reduceMotion],
  );

  const close = useCallback(() => {
    settle(false);
  }, [settle]);

  const noteOpen = useCallback(
    (open: boolean) => {
      if (open) {
        if (openRow && openRow !== self.current) {
          openRow.close();
        }
        self.current = {close};
        openRow = self.current;
        haptics.selection();
      } else if (openRow === self.current) {
        openRow = null;
      }
    },
    [close],
  );

  // A recycled or removed row must not stay registered as the open one.
  useEffect(
    () => () => {
      if (openRow === self.current) {
        openRow = null;
      }
    },
    [],
  );

  const pan = useMemo(
    () =>
      Gesture.Pan()
        .enabled(enabled && actions.length > 0)
        // Sideways only: a vertical drag belongs to the list.
        .activeOffsetX([-10, 10])
        .failOffsetY([-8, 8])
        .onStart(() => {
          'worklet';
          startProgress.value = progress.value;
        })
        .onUpdate(event => {
          'worklet';
          const moved = (event.translationX * direction) / width;
          const next = startProgress.value + moved;
          // Past fully open the row follows at a quarter of the finger.
          progress.value =
            next <= 0 ? 0 : next <= 1 ? next : 1 + (next - 1) * 0.25;
        })
        .onEnd(event => {
          'worklet';
          const velocity = event.velocityX * direction;
          const open =
            velocity > FLICK
              ? true
              : velocity < -FLICK
                ? false
                : progress.value > 0.5;
          settle(open);
          runOnJS(noteOpen)(open);
        }),
    [
      actions.length,
      direction,
      enabled,
      noteOpen,
      progress,
      settle,
      startProgress,
      width,
    ],
  );

  const rowStyle = useAnimatedStyle(() => ({
    transform: [{translateX: progress.value * width * direction}],
  }));

  if (!enabled || actions.length === 0) {
    return <>{children}</>;
  }

  return (
    <GestureDetector gesture={pan}>
      <View testID={testID} style={styles.container}>
        <View style={styles.actions} pointerEvents="box-none">
          {actions.map((action, index) => (
            <ActionButton
              key={action.id}
              action={action}
              progress={progress}
              // The button nearest the row appears first.
              order={(actions.length - 1 - index) / Math.max(1, actions.length)}
              testID={testID ? `${testID}-${action.id}` : undefined}
              onPress={() => {
                haptics.tap();
                close();
                noteOpen(false);
                onAction(action.id);
              }}
            />
          ))}
        </View>
        <Animated.View style={rowStyle}>{children}</Animated.View>
      </View>
    </GestureDetector>
  );
}

function ActionButton({
  action,
  progress,
  order,
  onPress,
  testID,
}: {
  action: SwipeAction;
  progress: SharedValue<number>;
  order: number;
  onPress: () => void;
  testID?: string;
}) {
  const style = useAnimatedStyle(() => {
    const shown = interpolate(
      progress.value,
      [order * 0.5, 0.6 + order * 0.4],
      [0, 1],
      'clamp',
    );
    return {opacity: shown, transform: [{scale: 0.7 + shown * 0.3}]};
  });
  return (
    <Animated.View style={style}>
      <PressableScale
        testID={testID}
        accessibilityRole="button"
        accessibilityLabel={action.label}
        onPress={onPress}
        style={styles.action(action.destructive === true)}>
        <Icon
          name={action.icon}
          size={20}
          color={action.destructive ? 'background' : 'textPrimary'}
        />
      </PressableScale>
    </Animated.View>
  );
}

const styles = StyleSheet.create(theme => ({
  container: {
    overflow: 'hidden',
    borderRadius: theme.radii.md,
  },
  actions: {
    ...StyleSheet.absoluteFillObject,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'flex-end',
    gap: ACTION_GAP,
    paddingEnd: END_INSET,
  },
  action: (destructive: boolean) => ({
    width: ACTION_WIDTH,
    height: 40,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: theme.radii.md,
    borderCurve: 'continuous',
    backgroundColor: destructive ? theme.colors.danger : theme.colors.surface,
  }),
}));
