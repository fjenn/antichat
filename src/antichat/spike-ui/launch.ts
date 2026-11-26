/**
 * Dev entry point of the scroll/keyboard/streaming spike.
 *
 * iOS:      launch argument `-antichatSpikeUI A` (or `B`), optional
 *           `-antichatSpikeUIAuto script30|script15|script60|model`.
 * Any OS:   a file `Documents/antichat-spike-ui.json`, e.g.
 *           {"list":"A","auto":"script30"} (Android has no launch arguments).
 * In the app: the spike screen has its own controls for all of this.
 */
import * as RNFS from '@dr.pogodin/react-native-fs';
import DeviceInfo from 'react-native-device-info';

import {getLaunchConfig} from '../spike/native';
import type {SourceKind} from './sources';
import type {ListKind} from './types';

export type SpikeUiConfig = {list: ListKind; auto?: SourceKind};

export const MARKER_FILE = 'antichat-spike-ui.json';

/** Debug builds only: `__DEV__` bundles and the side-by-side dev app ids. */
export function isDevBuild(): boolean {
  if (__DEV__) {
    return true;
  }
  const id = DeviceInfo.getBundleId();
  return id.endsWith('.dev') || id.endsWith('.antichatdev');
}

const parse = (list?: string, auto?: string): SpikeUiConfig => ({
  list: list === 'B' ? 'B' : 'A',
  auto: (['script15', 'script30', 'script60', 'model'] as const).find(
    s => s === auto,
  ),
});

/** Synchronous part: iOS launch arguments. */
export function launchArgConfig(): SpikeUiConfig | null {
  const options = getLaunchConfig().options;
  return options.antichatSpikeUI
    ? parse(options.antichatSpikeUI, options.antichatSpikeUIAuto)
    : null;
}

export async function markerFileConfig(): Promise<SpikeUiConfig | null> {
  try {
    const path = `${RNFS.DocumentDirectoryPath}/${MARKER_FILE}`;
    if (!(await RNFS.exists(path))) {
      return null;
    }
    const json = JSON.parse(await RNFS.readFile(path, 'utf8'));
    return parse(json.list, json.auto);
  } catch {
    return null;
  }
}
