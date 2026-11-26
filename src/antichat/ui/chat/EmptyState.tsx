import React from 'react';
import {ScrollView} from 'react-native';
import {useReanimatedKeyboardAnimation} from 'react-native-keyboard-controller';
import Animated, {
  FadeIn,
  FadeOut,
  useAnimatedStyle,
  useReducedMotion,
} from 'react-native-reanimated';
import {StyleSheet} from 'react-native-unistyles';

import type {Starter} from '../../contracts';
import {useT} from '../../locales';
import {PressableScale, Text} from '../primitives';

/** The greeting in the middle of a chat that has not started. */
export function Greeting({offline}: {offline: boolean}) {
  const t = useT();
  const reduceMotion = useReducedMotion();
  // Stays in the middle of what the keyboard leaves free.
  const keyboard = useReanimatedKeyboardAnimation();
  const lifted = useAnimatedStyle(() => ({
    transform: [{translateY: keyboard.height.value / 2}],
  }));
  return (
    <Animated.View
      key={offline ? 'offline' : 'normal'}
      entering={reduceMotion ? undefined : FadeIn.duration(220)}
      exiting={reduceMotion ? undefined : FadeOut.duration(120)}
      style={[styles.greeting, lifted]}>
      <Text
        testID="greeting"
        variant="title"
        align="center"
        accessibilityRole="header">
        {t(offline ? 'shell.offlineGreeting' : 'shell.greeting')}
      </Text>
      <Text variant="callout" color="textSecondary" align="center">
        {t(offline ? 'shell.offlineHint' : 'shell.greetingHint')}
      </Text>
    </Animated.View>
  );
}

export interface StartersProps {
  starters: readonly Starter[];
  onStarter: (starter: Starter) => void;
}

/**
 * Two-line suggestion cards in a row that scrolls sideways. They sit on top
 * of the composer and leave as soon as the user starts typing.
 */
export function Starters({starters, onStarter}: StartersProps) {
  const t = useT();
  const reduceMotion = useReducedMotion();
  return (
    <Animated.View
      entering={reduceMotion ? undefined : FadeIn.duration(220)}
      exiting={reduceMotion ? undefined : FadeOut.duration(120)}
      style={styles.bleed}>
      <ScrollView
        horizontal
        showsHorizontalScrollIndicator={false}
        keyboardShouldPersistTaps="handled"
        accessibilityLabel={t('shell.startersLabel')}
        contentContainerStyle={styles.starters}>
        {starters.map(starter => (
          <PressableScale
            key={starter.id}
            testID={`starter-${starter.id}`}
            accessibilityRole="button"
            accessibilityLabel={`${starter.label}. ${starter.prompt}`}
            haptic
            onPress={() => onStarter(starter)}
            style={styles.starter}>
            <Text variant="calloutStrong" numberOfLines={1}>
              {starter.label}
            </Text>
            <Text variant="callout" color="textSecondary" numberOfLines={1}>
              {starter.prompt}
            </Text>
          </PressableScale>
        ))}
      </ScrollView>
    </Animated.View>
  );
}

const styles = StyleSheet.create(theme => ({
  greeting: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    gap: theme.spacing.sm,
    paddingHorizontal: theme.spacing.xxxl,
  },
  // The row runs to the screen edges; the dock around it is inset.
  bleed: {
    marginHorizontal: -theme.spacing.md,
  },
  starters: {
    gap: theme.spacing.sm,
    paddingHorizontal: theme.spacing.md,
  },
  starter: {
    maxWidth: 264,
    gap: theme.spacing.xxs,
    paddingHorizontal: theme.spacing.lg,
    paddingVertical: theme.spacing.md,
    borderRadius: theme.radii.lg,
    borderCurve: 'continuous',
    backgroundColor: theme.colors.surface,
  },
}));
