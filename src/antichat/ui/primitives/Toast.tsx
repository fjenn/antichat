import React, {useEffect, useSyncExternalStore} from 'react';
import {AccessibilityInfo, View} from 'react-native';
import Animated, {
  FadeInUp,
  FadeOutUp,
  useReducedMotion,
} from 'react-native-reanimated';
import {StyleSheet} from 'react-native-unistyles';

import {motion} from '../../theme';
import {haptics} from './haptics';
import {Icon} from './Icon';
import type {IconName} from './icons';
import {PressableScale} from './PressableScale';
import {Text} from './Text';

export type ToastKind = 'info' | 'success' | 'error';

export interface ToastOptions {
  message: string;
  kind?: ToastKind;
  /** Milliseconds on screen. */
  duration?: number;
  /** One text button at the end of the toast ("Undo"). */
  action?: {label: string; onPress: () => void};
}

interface ToastState extends Required<Omit<ToastOptions, 'action'>> {
  id: number;
  action?: ToastOptions['action'];
}

const DEFAULT_DURATION = 2200;
/** A toast that offers an action stays long enough to reach it. */
const ACTION_DURATION = 5000;
const ICONS: Record<ToastKind, IconName | undefined> = {
  info: undefined,
  success: 'check',
  error: 'alert',
};

let current: ToastState | null = null;
let nextId = 1;
let timer: ReturnType<typeof setTimeout> | undefined;
const listeners = new Set<() => void>();

function emit(): void {
  listeners.forEach(listener => listener());
}

/**
 * Brief confirmations ("Copied") and non-blocking errors. One at a time; a
 * new toast replaces the one on screen.
 */
export const toast = {
  show(options: ToastOptions): void {
    const kind = options.kind ?? 'info';
    current = {
      id: nextId++,
      message: options.message,
      kind,
      duration:
        options.duration ??
        (options.action ? ACTION_DURATION : DEFAULT_DURATION),
      action: options.action,
    };
    if (kind === 'error') {
      haptics.error();
    } else if (kind === 'success') {
      haptics.success();
    }
    AccessibilityInfo.announceForAccessibility(options.message);
    clearTimeout(timer);
    timer = setTimeout(toast.hide, current.duration);
    emit();
  },
  hide(): void {
    clearTimeout(timer);
    if (current) {
      current = null;
      emit();
    }
  },
  /** The toast on screen, for tests. */
  current(): ToastOptions | null {
    return current;
  },
};

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}
const snapshot = () => current;

/** Mount once, above the navigator. */
export function ToastHost() {
  const state = useSyncExternalStore(subscribe, snapshot, snapshot);
  const reduceMotion = useReducedMotion();
  useEffect(() => () => clearTimeout(timer), []);
  if (!state) {
    return null;
  }
  const icon = ICONS[state.kind];
  return (
    <View pointerEvents="box-none" style={styles.host}>
      <Animated.View
        key={state.id}
        testID="toast"
        pointerEvents={state.action ? 'auto' : 'none'}
        entering={
          reduceMotion ? undefined : FadeInUp.duration(motion.duration.base)
        }
        exiting={
          reduceMotion ? undefined : FadeOutUp.duration(motion.duration.fast)
        }
        style={styles.toast}>
        {icon ? <Icon name={icon} size={16} color="onInverse" /> : null}
        <Text
          variant="calloutStrong"
          color="onInverse"
          numberOfLines={3}
          style={styles.message}>
          {state.message}
        </Text>
        {state.action ? (
          <PressableScale
            testID="toast-action"
            accessibilityRole="button"
            accessibilityLabel={state.action.label}
            hitSlop={12}
            haptic
            onPress={() => {
              const {action} = state;
              toast.hide();
              action?.onPress();
            }}
            style={styles.action}>
            <Text variant="calloutStrong" color="onInverse">
              {state.action.label}
            </Text>
          </PressableScale>
        ) : null}
      </Animated.View>
    </View>
  );
}

const styles = StyleSheet.create((theme, rt) => ({
  host: {
    position: 'absolute',
    top: rt.insets.top + theme.spacing.sm,
    left: theme.spacing.xl,
    right: theme.spacing.xl,
    alignItems: 'center',
  },
  toast: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.sm,
    minHeight: 40,
    paddingHorizontal: theme.spacing.lg,
    paddingVertical: theme.spacing.sm,
    borderRadius: theme.radii.pill,
    backgroundColor: theme.colors.inverse,
    boxShadow: theme.elevation.floating,
  },
  message: {
    flexShrink: 1,
  },
  action: {
    marginStart: theme.spacing.sm,
    paddingStart: theme.spacing.md,
    borderStartWidth: StyleSheet.hairlineWidth,
    borderStartColor: theme.colors.textTertiary,
  },
}));
