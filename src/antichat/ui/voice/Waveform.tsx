import React, {useEffect, useRef, useState} from 'react';
import {View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

const BARS = 28;

/** Scrolling level bars: the newest level enters on the right. */
export function Waveform({level, active}: {level: number; active: boolean}) {
  const history = useRef<number[]>(Array(BARS).fill(0));
  const latest = useRef(0);
  latest.current = active ? level : 0;
  const [, redraw] = useState(0);
  // Time scrolls the bars, not changes of the level: silence moves too.
  useEffect(() => {
    if (!active) {
      return;
    }
    const timer = setInterval(() => {
      history.current = [...history.current.slice(1), latest.current];
      redraw(n => n + 1);
    }, 90);
    return () => clearInterval(timer);
  }, [active]);
  return (
    <View
      style={styles.wave}
      accessibilityElementsHidden
      importantForAccessibility="no-hide-descendants">
      {history.current.map((value, index) => (
        <View key={index} style={styles.bar(value)} />
      ))}
    </View>
  );
}

const styles = StyleSheet.create(theme => ({
  wave: {
    height: 24,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 2,
  },
  bar: (value: number) => ({
    width: 2.5,
    height: 3 + Math.min(1, value) * 21,
    borderRadius: 2,
    backgroundColor: theme.colors.textSecondary,
  }),
}));
