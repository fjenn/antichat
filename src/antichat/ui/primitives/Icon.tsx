import React from 'react';
import {I18nManager, View} from 'react-native';
import {useUnistyles} from 'react-native-unistyles';

import type {ColorToken} from '../../theme';
import {DIRECTIONAL, glyphs, type IconName} from './icons';

export interface IconProps {
  name: IconName;
  size?: number;
  color?: ColorToken;
  strokeWidth?: number;
}

const MIRROR = {transform: [{scaleX: -1}]} as const;

/** Decorative by default: the control around it carries the label. */
export function Icon({
  name,
  size = 22,
  color = 'textPrimary',
  strokeWidth = 2,
}: IconProps) {
  const {theme} = useUnistyles();
  const Glyph = glyphs[name];
  const glyph = (
    <Glyph size={size} color={theme.colors[color]} strokeWidth={strokeWidth} />
  );
  if (I18nManager.isRTL && DIRECTIONAL.has(name)) {
    return (
      <View style={MIRROR} accessibilityElementsHidden>
        {glyph}
      </View>
    );
  }
  return glyph;
}
