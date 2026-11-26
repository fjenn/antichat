import React, {useEffect, useRef, useSyncExternalStore} from 'react';
import {StyleSheet, Text} from 'react-native';

import {runAuto} from './auto';
import {autoRequest, clearAutoRequest, subscribeAuto} from './debug';
import {JsFrameRecorder, useUiFrameRecorder} from './perf';

/**
 * Debug builds: runs the scroll-rule checks and the frame measurements on
 * the real chat screen when asked to (see `debug.ts`), and shows the phase.
 */
export function AutoRunner() {
  const source = useSyncExternalStore(subscribeAuto, autoRequest, autoRequest);
  const ui = useUiFrameRecorder();
  const js = useRef(new JsFrameRecorder()).current;
  const [phase, setPhase] = React.useState('');
  const started = useRef(false);

  useEffect(() => {
    if (!source || started.current) {
      return;
    }
    started.current = true;
    const timer = setTimeout(() => {
      runAuto(source, {
        setPhase,
        perfStart: () => {
          ui.start();
          js.start();
        },
        perfStop: () => ({js: js.stop(), ui: ui.stop()}),
      })
        .catch(error => setPhase(`failed: ${String(error)}`))
        .finally(() => {
          started.current = false;
          clearAutoRequest();
        });
    }, 2500);
    return () => clearTimeout(timer);
  }, [js, source, ui]);

  if (!phase) {
    return null;
  }
  return (
    <Text testID="auto-phase" pointerEvents="none" style={styles.phase}>
      {phase}
    </Text>
  );
}

const styles = StyleSheet.create({
  phase: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    fontSize: 9,
    textAlign: 'center',
    color: '#888',
  },
});
