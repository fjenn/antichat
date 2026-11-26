import React from 'react';
import {View, type StyleProp, type ViewStyle} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import type {ColorToken} from '../../theme';
import {GlassSurface} from './GlassSurface';
import {Icon} from './Icon';
import type {IconName} from './icons';
import {PressableScale} from './PressableScale';

export type IconButtonVariant = 'plain' | 'filled' | 'accent' | 'glass';

export interface IconButtonProps {
  icon: IconName;
  /** Read by VoiceOver / TalkBack. Required: an icon has no text. */
  accessibilityLabel: string;
  accessibilityHint?: string;
  onPress?: () => void;
  onLongPress?: () => void;
  variant?: IconButtonVariant;
  /** Diameter of the visible button. The touch target is never under 44. */
  size?: number;
  iconSize?: number;
  disabled?: boolean;
  haptic?: boolean;
  style?: StyleProp<ViewStyle>;
  testID?: string;
}

const ICON_COLOR: Record<IconButtonVariant, ColorToken> = {
  plain: 'textPrimary',
  filled: 'textPrimary',
  accent: 'onAccent',
  glass: 'textPrimary',
};

export function IconButton({
  icon,
  accessibilityLabel,
  accessibilityHint,
  onPress,
  onLongPress,
  variant = 'plain',
  size = 44,
  iconSize = 22,
  disabled = false,
  haptic = true,
  style,
  testID,
}: IconButtonProps) {
  const slop = Math.max(0, (44 - size) / 2);
  const glyph = (
    <Icon
      name={icon}
      size={iconSize}
      color={disabled ? 'textTertiary' : ICON_COLOR[variant]}
    />
  );
  return (
    <PressableScale
      testID={testID}
      accessibilityRole="button"
      accessibilityLabel={accessibilityLabel}
      accessibilityHint={accessibilityHint}
      accessibilityState={{disabled}}
      disabled={disabled}
      haptic={haptic}
      hitSlop={slop}
      onPress={onPress}
      onLongPress={onLongPress}
      style={style}>
      {variant === 'glass' ? (
        // The glass never takes the touch: the Pressable around it does.
        <View pointerEvents="none">
          <GlassSurface style={styles.box(size)}>{glyph}</GlassSurface>
        </View>
      ) : (
        <View style={[styles.box(size), styles.fill(variant, disabled)]}>
          {glyph}
        </View>
      )}
    </PressableScale>
  );
}

const styles = StyleSheet.create(theme => ({
  box: (size: number) => ({
    width: size,
    height: size,
    borderRadius: size / 2,
    alignItems: 'center',
    justifyContent: 'center',
  }),
  fill: (variant: IconButtonVariant, disabled: boolean) => ({
    backgroundColor:
      variant === 'accent'
        ? disabled
          ? theme.colors.surfacePressed
          : theme.colors.accent
        : variant === 'filled'
          ? theme.colors.surface
          : 'transparent',
  }),
}));
