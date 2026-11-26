import {ConnectionKind, ConnectivitySource, NetworkReading} from './types';

/**
 * The part of `@react-native-community/netinfo` this app uses, described
 * structurally. The package is added by the integration lane; the adapter layer
 * passes the module in, so nothing here imports it:
 *
 *   import NetInfo from '@react-native-community/netinfo';
 *   const connectivity = new ConnectivityStore(netInfoSource(NetInfo));
 */
export interface NetInfoStateLike {
  type: string;
  isConnected: boolean | null;
  isInternetReachable?: boolean | null;
  details?: {isConnectionExpensive?: boolean} | null;
}

export interface NetInfoLike {
  fetch(): Promise<NetInfoStateLike>;
  addEventListener(listener: (state: NetInfoStateLike) => void): () => void;
}

const kindOf = (type: string): ConnectionKind => {
  switch (type) {
    case 'wifi':
    case 'ethernet':
      return 'wifi';
    case 'cellular':
      return 'cellular';
    case 'none':
      return 'none';
    case 'unknown':
      return 'unknown';
    default:
      // bluetooth, vpn, wimax, other
      return 'other';
  }
};

export function toReading(state: NetInfoStateLike): NetworkReading {
  const kind = kindOf(state.type);
  // `null` means "not determined yet": treated as connected, so the app does
  // not flash "Offline" at launch. Only an explicit false counts.
  const connected =
    state.isConnected !== false &&
    state.isInternetReachable !== false &&
    kind !== 'none';
  return {
    connected,
    kind,
    expensive:
      kind === 'cellular' || state.details?.isConnectionExpensive === true,
  };
}

export function netInfoSource(netInfo: NetInfoLike): ConnectivitySource {
  return {
    read: async () => toReading(await netInfo.fetch()),
    subscribe: listener =>
      netInfo.addEventListener(state => listener(toReading(state))),
  };
}
