import React from 'react';
import {StyleSheet} from 'react-native';
import {GestureHandlerRootView} from 'react-native-gesture-handler';

/**
 * Gesture Handler 3 removed `gestureHandlerRootHOC`; upstream `App.tsx` still
 * wraps its screens with it. Same behaviour as the removed helper.
 */
export function gestureHandlerRootHOC<P extends object>(
  Component: React.ComponentType<P>,
): React.ComponentType<P> {
  function Wrapper(props: P) {
    return (
      <GestureHandlerRootView style={styles.root}>
        <Component {...props} />
      </GestureHandlerRootView>
    );
  }
  Wrapper.displayName = `gestureHandlerRootHOC(${
    Component.displayName || Component.name
  })`;
  return Wrapper;
}

const styles = StyleSheet.create({root: {flex: 1}});
