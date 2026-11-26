/**
 * Dev entry of the model engine (M5). Reached only in debug builds, when
 * `Documents/antichat-m5.json` exists (see config.ts).
 */
import React, {useEffect, useState, type ComponentType} from 'react';

import {isDevBuild} from '../../../spike-ui/launch';

import {ModelDevConfig, readDevConfig} from './config';

/** Wraps the next root: shows the dev screen when the marker file asks for it. */
export function modelDevRoot(next: ComponentType<any>): ComponentType<any> {
  if (!isDevBuild()) {
    return next;
  }
  return function ModelDevGate(props: any) {
    const [config, setConfig] = useState<ModelDevConfig | null | undefined>(
      undefined,
    );
    useEffect(() => {
      readDevConfig().then(setConfig);
    }, []);
    if (config === undefined) {
      return null;
    }
    if (config === null || (config as {auto?: string}).auto === 'app') {
      const Next = next;
      return <Next {...props} />;
    }
    const {ModelDevScreen} = require('./ModelDevScreen');
    return <ModelDevScreen config={config} />;
  };
}
