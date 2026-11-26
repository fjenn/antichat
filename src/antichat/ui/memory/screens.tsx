import React from 'react';

import {MemoryScreen} from './MemoryScreen';

/** Route M9 adds to the main stack; intersect into `MainStackParams`. */
export type MemoryParams = {
  Memory: undefined;
};

interface StackLike {
  Screen: React.ComponentType<any>;
}

/**
 * The manage screen, for the main stack:
 *
 *   <Stack.Navigator>
 *     …
 *     {memoryScreens(Stack)}
 *   </Stack.Navigator>
 */
export function memoryScreens(Stack: StackLike): React.ReactElement {
  return <Stack.Screen name="Memory" component={MemoryScreen} />;
}
