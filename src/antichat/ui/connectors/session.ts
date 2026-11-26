/**
 * The app's connectors store, wired to the real connectivity flag. Screens
 * call `useConnectors()`; tests pass their own store to the views instead.
 */
import {connectivity, startConnectivity} from '../../adapters/connectivity';
import {installConnectors} from '../../engine/mcp/install';
import type {ConnectorsStore} from '../../engine/mcp/store';

let started = false;

export function useConnectors(): ConnectorsStore {
  if (!started) {
    started = true;
    startConnectivity().catch(() => {});
  }
  return installConnectors({isOnline: () => connectivity.online});
}
