import React from 'react';
import {View} from 'react-native';
import {StyleSheet, useUnistyles} from 'react-native-unistyles';

import type {ColorToken} from '../../theme';

/** Small shapes the icon set does not have yet (pause, play, skip). */
export function Glyph({
  name,
  color = 'textPrimary',
  size = 16,
}: {
  name: 'pause' | 'play' | 'previous' | 'next';
  color?: ColorToken;
  size?: number;
}) {
  const {theme} = useUnistyles();
  const tint = theme.colors[color];
  const bar = {
    width: size * 0.26,
    height: size,
    borderRadius: 1.5,
    backgroundColor: tint,
  };
  const triangle = (flip: boolean) => ({
    width: 0,
    height: 0,
    borderTopWidth: size / 2,
    borderBottomWidth: size / 2,
    borderTopColor: 'transparent',
    borderBottomColor: 'transparent',
    ...(flip
      ? {borderRightWidth: size * 0.8, borderRightColor: tint}
      : {borderLeftWidth: size * 0.8, borderLeftColor: tint}),
  });
  if (name === 'pause') {
    return (
      <View style={[styles.row, {gap: size * 0.26}]}>
        <View style={bar} />
        <View style={bar} />
      </View>
    );
  }
  if (name === 'play') {
    return <View style={triangle(false)} />;
  }
  const thin = {...bar, width: size * 0.16};
  return (
    <View style={[styles.row, styles.tight]}>
      {name === 'previous' ? <View style={thin} /> : null}
      <View style={triangle(name === 'previous')} />
      {name === 'next' ? <View style={thin} /> : null}
    </View>
  );
}

const styles = StyleSheet.create({
  row: {flexDirection: 'row', alignItems: 'center'},
  tight: {gap: 1},
});
