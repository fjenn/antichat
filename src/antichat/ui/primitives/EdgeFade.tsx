import React from 'react';
import {StyleSheet, type StyleProp, type ViewStyle} from 'react-native';
import LinearGradient from 'react-native-linear-gradient';
import {useUnistyles} from 'react-native-unistyles';

import {withAlpha, type ColorToken} from '../../theme';

export interface EdgeFadeProps {
  /** The edge the content disappears into. */
  edge: 'top' | 'bottom';
  height: number;
  /**
   * Part of the height, from the edge, that is fully opaque (the status bar,
   * the home indicator).
   */
  solid?: number;
  color?: ColorToken;
  style?: StyleProp<ViewStyle>;
}

/**
 * Fades scrolling content out under floating controls, so text never collides
 * with the top bar or the composer. Lay it over the scroll view, under the
 * controls. It never takes touches.
 */
export function EdgeFade({
  edge,
  height,
  solid = 0,
  color = 'background',
  style,
}: EdgeFadeProps) {
  const {theme} = useUnistyles();
  const base = theme.colors[color];
  const stop = Math.min(0.9, solid / height);
  const opaque = withAlpha(base, 1);
  const soft = withAlpha(base, 0.85);
  const clear = withAlpha(base, 0);
  const top = edge === 'top';
  return (
    <LinearGradient
      pointerEvents="none"
      colors={top ? [opaque, soft, clear] : [clear, soft, opaque]}
      locations={
        top
          ? [stop, stop + (1 - stop) * 0.45, 1]
          : [0, (1 - stop) * 0.55, 1 - stop]
      }
      style={[styles.fade, top ? styles.top : styles.bottom, {height}, style]}
    />
  );
}

const styles = StyleSheet.create({
  fade: {position: 'absolute', left: 0, right: 0},
  top: {top: 0},
  bottom: {bottom: 0},
});
