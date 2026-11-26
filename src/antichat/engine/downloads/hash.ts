import * as RNFS from '@dr.pogodin/react-native-fs';

import {antichatNative, antichatNativeEvents} from './native';

let counter = 0;

/**
 * SHA-256 of a file as lower-case hex, read in pieces natively so a multi-GB
 * model never sits in memory. (`RNFS.hash` reads the whole file into one
 * buffer on iOS; it is only the fallback when our module is absent.)
 */
export async function sha256File(
  path: string,
  onProgress?: (fraction: number) => void,
): Promise<string> {
  if (!antichatNative) {
    return (await RNFS.hash(path, 'sha256')).toLowerCase();
  }
  const token = `hash-${++counter}`;
  const subscription = onProgress
    ? antichatNativeEvents()?.addListener(
        'onHashProgress',
        (event: {token: string; fraction: number}) => {
          if (event.token === token) {
            onProgress(event.fraction);
          }
        },
      )
    : undefined;
  try {
    return (await antichatNative.hashFile(path, token)).toLowerCase();
  } finally {
    subscription?.remove();
  }
}
