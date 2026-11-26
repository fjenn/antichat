/**
 * Entry of the M0 scroll/keyboard/streaming spike (see docs/antichat/M0-DECISION.md).
 * Reached only in debug builds; see launch.ts for how.
 */
import React, {useEffect, useState, type ComponentType} from 'react';

import {
  isDevBuild,
  launchArgConfig,
  markerFileConfig,
  type SpikeUiConfig,
} from './launch';

/**
 * Returns the root component when the spike may be requested, else null.
 * With a launch argument the spike mounts at once; otherwise a gate checks
 * the marker file first and falls through to the app.
 */
export function spikeUiRoot(
  loadApp: () => ComponentType<any>,
): ComponentType<any> | null {
  if (!isDevBuild()) {
    return null;
  }
  const fromArgs = launchArgConfig();
  return function SpikeUiGate(props: any) {
    const [config, setConfig] = useState<SpikeUiConfig | null | undefined>(
      fromArgs ?? undefined,
    );
    useEffect(() => {
      if (config === undefined) {
        markerFileConfig().then(setConfig);
      }
    }, [config]);
    if (config === undefined) {
      return null;
    }
    if (config === null) {
      const App = loadApp();
      return <App {...props} />;
    }
    const {SpikeUIScreen} = require('./SpikeUIScreen');
    return <SpikeUIScreen config={config} />;
  };
}
