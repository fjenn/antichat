/**
 * Dev entry of the model engine (M5). Debug builds only.
 *
 * A file `Documents/antichat-m5.json` (Android: `files/antichat-m5.json`)
 * replaces the app's root with the model dev screen. Written by
 * `tools/antichat/m5-run.sh`, or by hand. All fields are optional:
 *
 *   {
 *     "auto": "firstRun",                      // run the first-run path unattended
 *     "filesBaseUrl": "http://127.0.0.1:8765", // model files from tools/antichat/m5-server.py
 *     "catalogOverrideUrl": ".../catalog.json",// unsigned catalogue, used as the bundled one
 *     "catalogUrl": ".../signed/catalog.json", // signed catalogue for the refresh check
 *     "catalogKey": "<base64 public key>",     // the dev key that signs it
 *     "catalogChecks": [".../signed/tampered.json"], // verify and report only
 *     "failInit": ["gemma-4-e4b-qat"],         // these models fail to load with "out of memory"
 *     "hangInit": ["lfm3-1.7b"],               // these models never finish loading (kill the app then)
 *     "device": {"totalRamGb": 4, "availableGb": 2}, // act as a smaller phone
 *     "prompt": "Write one sentence about the sea.",
 *     "lab": {...}                             // downloader lab, see lab.ts
 *   }
 */
import * as RNFS from '@dr.pogodin/react-native-fs';

import type {LabConfig} from './lab';

export interface ModelDevConfig {
  auto?: 'firstRun' | 'lab';
  filesBaseUrl?: string;
  catalogOverrideUrl?: string;
  catalogUrl?: string;
  catalogKey?: string;
  /** Catalogue URLs to verify with `catalogKey` and report, nothing adopted. */
  catalogChecks?: string[];
  failInit?: string[];
  /** These models hang in the load, so the app can be killed during it. */
  hangInit?: string[];
  device?: {totalRamGb?: number; availableGb?: number};
  prompt?: string;
  maxTokens?: number;
  lab?: LabConfig;
}

export const DEV_MARKER_FILE = 'antichat-m5.json';
export const DEV_DIR = `${RNFS.DocumentDirectoryPath}/antichat-m5`;

export async function readDevConfig(): Promise<ModelDevConfig | null> {
  try {
    const path = `${RNFS.DocumentDirectoryPath}/${DEV_MARKER_FILE}`;
    if (!(await RNFS.exists(path))) {
      return null;
    }
    return JSON.parse(await RNFS.readFile(path, 'utf8')) as ModelDevConfig;
  } catch {
    return null;
  }
}
