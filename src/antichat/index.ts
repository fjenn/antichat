/**
 * AntiChat entry point. Everything AntiChat-specific lives under src/antichat
 * (see docs/antichat/FORK.md); upstream files only call into this module.
 */
import {createElement} from 'react';
import type {ComponentType} from 'react';

import {getLaunchConfig} from './spike/native';

/**
 * Picks the root component. Launched with `-antichatSpike 1` (or the
 * ANTICHAT_SPIKE env var) in a debug build, the app runs the unattended spike
 * harness instead of the normal UI, so the upstream app graph is never loaded.
 */
export function antichatRoot(
  loadApp: () => ComponentType<any>,
): ComponentType<any> {
  if (__DEV__ && getLaunchConfig().enabled) {
    return require('./spike/SpikeScreen').SpikeScreen;
  }
  // Debug builds: the M0 scroll/keyboard/streaming spike (spike-ui/launch.ts).
  const spikeUi = require('./spike-ui').spikeUiRoot(loadApp);
  if (!require('./spike-ui/launch').isDevBuild()) {
    return loadApp();
  }
  // Debug builds: the model engine dev screen (engine/models/dev/config.ts).
  // The engine dev run wraps it ("auto": "engine" in the same marker file).
  return require('./engine/dev').engineDevRoot(
    require('./engine/models/dev').modelDevRoot(spikeUi ?? lazyApp(loadApp)),
  );
}

/** The app root, loaded only when it is rendered (keeps dev roots light). */
function lazyApp(loadApp: () => ComponentType<any>): ComponentType<any> {
  let App: ComponentType<any> | undefined;
  return function AntiChatApp(props: any) {
    App ??= loadApp();
    return createElement(App, props);
  };
}
