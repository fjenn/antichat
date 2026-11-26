/**
 * Hidden developer screen: shown instead of the app when a debug build is
 * launched with `-antichatSpike 1`. Starts the run on mount; no taps needed.
 */
import React, {useEffect, useRef, useState} from 'react';
import {SafeAreaView, ScrollView, StyleSheet, Text} from 'react-native';

import {runSpike} from './runner';

let started = false;

export const SpikeScreen = () => {
  const [lines, setLines] = useState<string[]>(['AntiChat spike harness']);
  const scroll = useRef<React.ElementRef<typeof ScrollView>>(null);

  useEffect(() => {
    if (started) {
      return; // survive fast refresh / remount without a second run
    }
    started = true;
    const log = (line: string) =>
      setLines(prev => [
        ...prev.slice(-300),
        `${new Date().toLocaleTimeString()} ${line}`,
      ]);
    runSpike(log).catch(e => log(`spike aborted: ${String(e?.message ?? e)}`));
  }, []);

  return (
    <SafeAreaView style={styles.root}>
      <ScrollView
        ref={scroll}
        contentContainerStyle={styles.content}
        onContentSizeChange={() =>
          scroll.current?.scrollToEnd({animated: false})
        }>
        {lines.map((line, i) => (
          <Text
            key={i}
            style={styles.line}
            testID={i === lines.length - 1 ? 'spike-last-line' : undefined}>
            {line}
          </Text>
        ))}
      </ScrollView>
    </SafeAreaView>
  );
};

const styles = StyleSheet.create({
  root: {flex: 1, backgroundColor: '#0b0b0c'},
  content: {padding: 12},
  line: {color: '#d7d7db', fontFamily: 'Menlo', fontSize: 11, marginBottom: 3},
});
