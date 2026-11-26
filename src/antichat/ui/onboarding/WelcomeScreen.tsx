import React, {useEffect, useRef} from 'react';
import {devToolsEnabled} from '../../app/flags';
import {Pressable, View} from 'react-native';
import Animated, {
  Easing,
  useAnimatedStyle,
  useReducedMotion,
  useSharedValue,
  withDelay,
  withRepeat,
  withTiming,
} from 'react-native-reanimated';
import {StyleSheet} from 'react-native-unistyles';

import {useT} from '../../locales';
import {Button, Icon, Sheet, Text, type SheetHandle} from '../primitives';

export interface WelcomeScreenProps {
  /** Size of the download first run will make, once the phone is known. */
  downloadSize?: string;
  offline?: boolean;
  onStart: () => void;
}

/**
 * The only screen of first run. One sentence, one button; the app picks the
 * model, so there is nothing to choose.
 */
export function WelcomeScreen({
  downloadSize,
  offline = false,
  onStart,
}: WelcomeScreenProps) {
  const t = useT();
  return (
    <View testID="welcome" style={styles.screen}>
      <View style={styles.hero}>
        {devToolsEnabled() ? <ScenarioDoor /> : <Orb />}
        <View style={styles.texts}>
          <Text
            variant="largeTitle"
            align="center"
            accessibilityRole="header"
            style={styles.title}>
            {t('firstRun.title')}
          </Text>
          <Text color="textSecondary" align="center" style={styles.subtitle}>
            {t('firstRun.subtitle')}
          </Text>
        </View>
      </View>
      <View style={styles.footer}>
        {offline ? (
          <View style={styles.offline}>
            <Icon name="offline" size={16} color="textSecondary" />
            <Text variant="footnote" color="textSecondary" style={styles.grow}>
              {t('firstRun.offline')}
            </Text>
          </View>
        ) : null}
        <Button
          testID="get-started"
          label={t('firstRun.start')}
          accessibilityHint={t('firstRun.startHint')}
          size="lg"
          fullWidth
          onPress={onStart}
        />
        <Text
          testID="welcome-footnote"
          variant="footnote"
          color="textTertiary"
          align="center">
          {downloadSize
            ? t('firstRun.footnote', {size: downloadSize})
            : t('firstRun.footnoteUnknown')}
        </Text>
      </View>
    </View>
  );
}

/**
 * Debug builds: a long press on the dot opens the scripted backend's
 * scenario (cellular, low storage, a failure) before first run starts.
 */
function ScenarioDoor() {
  const sheet = useRef<SheetHandle>(null);
  const {ScenarioControls} = require('../models/runtime/ScenarioControls');
  return (
    <>
      <Pressable
        testID="welcome-orb"
        accessible={false}
        delayLongPress={600}
        onLongPress={() => {
          sheet.current?.present().catch(() => {});
        }}>
        <Orb />
      </Pressable>
      <Sheet ref={sheet} testID="scenario-sheet">
        <ScenarioControls />
      </Sheet>
    </>
  );
}

/** A quiet breathing dot in the accent colour. Still under Reduce Motion. */
function Orb() {
  const reduceMotion = useReducedMotion();
  const breath = useSharedValue(0);
  useEffect(() => {
    if (reduceMotion) {
      return;
    }
    breath.value = withDelay(
      300,
      withRepeat(
        withTiming(1, {duration: 2600, easing: Easing.inOut(Easing.sin)}),
        -1,
        true,
      ),
    );
  }, [breath, reduceMotion]);
  const core = useAnimatedStyle(() => ({
    transform: [{scale: 1 + breath.value * 0.08}],
  }));
  const halo = useAnimatedStyle(() => ({
    opacity: 0.55 - breath.value * 0.35,
    transform: [{scale: 1.25 + breath.value * 0.35}],
  }));
  return (
    <View style={styles.orbBox} accessibilityElementsHidden>
      <Animated.View style={[styles.halo, halo]} />
      <Animated.View style={[styles.orb, core]} />
    </View>
  );
}

const ORB = 56;

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
    gap: theme.spacing.xxxl,
  },
  texts: {
    alignItems: 'center',
    gap: theme.spacing.md,
  },
  title: {
    fontSize: 34,
    lineHeight: 40,
    letterSpacing: -0.8,
  },
  subtitle: {
    maxWidth: 280,
    fontSize: 17,
    lineHeight: 25,
  },
  orbBox: {
    width: ORB * 2,
    height: ORB * 2,
    alignItems: 'center',
    justifyContent: 'center',
  },
  orb: {
    width: ORB,
    height: ORB,
    borderRadius: ORB / 2,
    backgroundColor: theme.colors.accent,
  },
  halo: {
    position: 'absolute',
    width: ORB,
    height: ORB,
    borderRadius: ORB / 2,
    backgroundColor: theme.colors.accentSoft,
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
}));
