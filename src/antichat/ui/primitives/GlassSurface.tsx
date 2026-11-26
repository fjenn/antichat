import React from 'react';
import {Platform, View, type StyleProp, type ViewStyle} from 'react-native';
import {LiquidGlassView, isLiquidGlassSupported} from '@callstack/liquid-glass';
import {BlurView} from '@sbaiahmed1/react-native-blur';
import {StyleSheet, useUnistyles} from 'react-native-unistyles';

/** True on iOS 26 and later, where the system draws real glass. */
export const HAS_LIQUID_GLASS = Platform.OS === 'ios' && isLiquidGlassSupported;

/** Older iOS gets a blurred material; Android gets a near-opaque fill. */
const HAS_BLUR = Platform.OS === 'ios' && !HAS_LIQUID_GLASS;

export interface GlassSurfaceProps {
  children?: React.ReactNode;
  /** Corner radius; the default makes a capsule. */
  radius?: number;
  /** The glass reacts to touch (iOS 26). Use for buttons. */
  interactive?: boolean;
  style?: StyleProp<ViewStyle>;
  testID?: string;
}

/**
 * A surface that floats over content: top-bar buttons, the composer.
 *
 * - iOS 26+: Liquid Glass.
 * - Older iOS: system blur with a tint and a hairline edge.
 * - Android: a near-opaque fill with the same edge and shadow. No blur: it is
 *   costly there and looks different from phone to phone.
 */
export function GlassSurface({
  children,
  radius = 999,
  interactive = false,
  style,
  testID,
}: GlassSurfaceProps) {
  const {theme} = useUnistyles();

  if (HAS_LIQUID_GLASS) {
    return (
      <LiquidGlassView
        testID={testID}
        effect="regular"
        interactive={interactive}
        colorScheme={theme.scheme}
        style={[styles.glass(radius), style]}>
        {children}
      </LiquidGlassView>
    );
  }

  return (
    <View testID={testID} style={[styles.fallback(radius, HAS_BLUR), style]}>
      {HAS_BLUR ? (
        <View style={styles.clip(radius)} pointerEvents="none">
          <BlurView
            blurType={theme.dark ? 'dark' : 'light'}
            blurAmount={theme.blur.glass}
            reducedTransparencyFallbackColor={theme.colors.glassSolid}
            style={styles.fill}
          />
          <View style={styles.tint} />
        </View>
      ) : null}
      {children}
    </View>
  );
}

const styles = StyleSheet.create(theme => ({
  glass: (radius: number) => ({
    borderRadius: radius,
    borderCurve: 'continuous',
  }),
  fallback: (radius: number, blurred: boolean) => ({
    borderRadius: radius,
    borderCurve: 'continuous',
    backgroundColor: blurred ? 'transparent' : theme.colors.glassSolid,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: theme.colors.glassBorder,
    boxShadow: theme.elevation.raised,
  }),
  clip: (radius: number) => ({
    ...StyleSheet.absoluteFillObject,
    borderRadius: radius,
    borderCurve: 'continuous',
    overflow: 'hidden',
  }),
  fill: {
    ...StyleSheet.absoluteFillObject,
  },
  tint: {
    ...StyleSheet.absoluteFillObject,
    backgroundColor: theme.colors.glassTint,
  },
}));
