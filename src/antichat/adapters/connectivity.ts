/**
 * Connectivity adapter (M5): NetInfo behind the one `online` flag.
 *
 * NetInfo's reachability probe is switched off. By default it requests
 * `clients3.google.com/generate_204` every minute; AntiChat makes no request
 * the user did not cause. Without the probe `online` follows the interface state (Wi-Fi/cellular up or
 * down, airplane mode), which is what the flag is for. A network without
 * internet behind it shows as an ordinary failed request in the tool that
 * tried it.
 */
import NetInfo from '@react-native-community/netinfo';

import {
  ConnectivityStore,
  NetInfoLike,
  NetInfoStateLike,
  netInfoSource,
} from '../engine/connectivity';

NetInfo.configure({reachabilityShouldRun: () => false});

/**
 * With the probe off NetInfo reports `isInternetReachable: false` for every
 * state, connected or not. It carries no information, so it is dropped (null
 * means "not determined") before the reading is taken.
 */
const withoutReachability = (state: NetInfoStateLike): NetInfoStateLike => ({
  type: state.type,
  isConnected: state.isConnected,
  isInternetReachable: null,
  details: state.details,
});

const source: NetInfoLike = {
  fetch: async () => withoutReachability(await NetInfo.fetch()),
  addEventListener: listener =>
    NetInfo.addEventListener(state => listener(withoutReachability(state))),
};

export const connectivity = new ConnectivityStore(netInfoSource(source));

let started: Promise<void> | null = null;

/** Start listening (idempotent). Resolves after the first reading. */
export function startConnectivity(): Promise<void> {
  started ??= connectivity.start();
  return started;
}
