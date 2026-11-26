import React from 'react';
import {Text as RNText, type TextProps as RNTextProps} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {typography, type ColorToken, type TextVariant} from '../../theme';

export interface TextProps extends RNTextProps {
  variant?: TextVariant;
  color?: ColorToken;
  align?: 'auto' | 'center' | 'left' | 'right';
}

/**
 * All text in the app. Sizes follow Dynamic Type / Android font scale up to
 * the cap of the variant; pass `maxFontSizeMultiplier` to tighten it.
 */
export function Text({
  variant = 'body',
  color = 'textPrimary',
  align = 'auto',
  style,
  maxFontSizeMultiplier,
  ...rest
}: TextProps) {
  return (
    <RNText
      {...rest}
      maxFontSizeMultiplier={
        maxFontSizeMultiplier ?? typography[variant].maxFontSizeMultiplier
      }
      style={[styles.text(variant, color, align), style]}
    />
  );
}

const styles = StyleSheet.create(theme => ({
  text: (
    variant: TextVariant,
    color: ColorToken,
    align: NonNullable<TextProps['align']>,
  ) => {
    const type = theme.typography[variant];
    return {
      fontSize: type.fontSize,
      lineHeight: type.lineHeight,
      fontWeight: type.fontWeight,
      letterSpacing: type.letterSpacing,
      color: theme.colors[color],
      textAlign: align,
      // Line height must grow with the text or large sizes clip.
      includeFontPadding: false,
    };
  },
}));
