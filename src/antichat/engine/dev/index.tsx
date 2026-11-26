/**
 * Dev entry of the whole engine. Debug builds only: reached when
 * `Documents/antichat-m5.json` (the model dev marker, see
 * `models/dev/config.ts`) carries `"auto": "engine"`.
 *
 *   {"auto": "engine", "filesBaseUrl": "http://127.0.0.1:8765",
 *    "device": {"totalRamGb": 8, "availableGb": 5},
 *    "steps": [
 *      {"type": "memory", "text": "User is allergic to peanuts"},
 *      {"type": "chat", "text": "What did Apple announce this week?"},
 *      {"type": "chat", "text": "Suggest a snack for me.", "newChat": true}
 *    ]}
 *
 * It installs the engine through `installEngine()` exactly as the app root
 * does, brings a model up, and plays the steps through upstream's real send
 * path (`useChatSession`), so prompt, tools, memory and files are exercised
 * together. Results go to `Documents/antichat-m5/events.log` and
 * `status.json`; drive it with `tools/antichat/m5-run.sh`.
 */
import React, {useEffect, useState, type ComponentType} from 'react';

import {isDevBuild} from '../../spike-ui/launch';
import {readDevConfig} from '../models/dev/config';

import type {EngineDevConfig} from './types';

export function engineDevRoot(next: ComponentType<any>): ComponentType<any> {
  if (!isDevBuild()) {
    return next;
  }
  return function EngineDevGate(props: any) {
    const [config, setConfig] = useState<EngineDevConfig | null | undefined>(
      undefined,
    );
    useEffect(() => {
      readDevConfig().then(read => setConfig(read as EngineDevConfig | null));
    }, []);
    if (config === undefined) {
      return null;
    }
    if ((config as {auto?: string} | null)?.auto === 'app' && config) {
      // The normal app, with model files from the local server
      // (`{"auto": "app", "filesBaseUrl": "http://127.0.0.1:8765"}`) so a
      // simulator never downloads from the internet what the Mac has.
      const GB = 1024 ** 3;
      const device = config.device;
      require('../../adapters/model').setDevRuntimeOptions({
        filesBaseUrl: config.filesBaseUrl,
        mapDevice: device
          ? (snapshot: {totalRamBytes: number; availableBytes: number}) => ({
              ...snapshot,
              totalRamBytes: device.totalRamGb
                ? device.totalRamGb * GB
                : snapshot.totalRamBytes,
              availableBytes: device.availableGb
                ? device.availableGb * GB
                : snapshot.availableBytes,
            })
          : undefined,
      });
      const Next = next;
      return <Next {...props} />;
    }
    if (config?.auto !== 'engine') {
      const Next = next;
      return <Next {...props} />;
    }
    const {EngineDevScreen} = require('./EngineDevScreen');
    return <EngineDevScreen config={config} />;
  };
}
