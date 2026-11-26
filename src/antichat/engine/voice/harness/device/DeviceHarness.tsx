import React, {useEffect, useState} from 'react';
import {ScrollView, StyleSheet, Text} from 'react-native';

import {runHarness} from './run';

/** Runs the voice harness once and shows its log. */
export function DeviceHarness() {
  const [lines, setLines] = useState<string[]>(['voice harness']);
  useEffect(() => {
    runHarness(line => setLines(previous => [...previous.slice(-200), line]));
  }, []);
  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {lines.map((line, index) => (
        <Text key={index} style={styles.line}>
          {line}
        </Text>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: {flex: 1, backgroundColor: '#000'},
  content: {padding: 16, paddingTop: 64},
  line: {color: '#ddd', fontSize: 11, marginBottom: 4},
});
