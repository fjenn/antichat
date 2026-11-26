/**
 * Switching connectors on: one store for the app, its tools in the tool
 * catalogue. Nothing here makes a request; the first one happens when the
 * user opens the Connectors screen or the model calls a connector tool.
 */
import {createPlatformDeps} from './platform';
import {ConnectorsStore} from './store';
import {registerConnectorTools} from './tools';

let store: ConnectorsStore | null = null;
let uninstall: (() => void) | null = null;

export interface ConnectorsOptions {
  /** The app's connectivity flag (observable, so screens follow it). */
  isOnline?: () => boolean;
}

/** Idempotent. Returns the app's connectors store. */
export function installConnectors(
  options: ConnectorsOptions = {},
): ConnectorsStore {
  if (!store) {
    const created = new ConnectorsStore(
      createPlatformDeps(options.isOnline ?? (() => true)),
    );
    store = created;
    created
      .load()
      .catch(() => {})
      .finally(() => {
        if (store === created) {
          uninstall = registerConnectorTools(created);
        }
      });
  }
  return store;
}

export function getConnectors(): ConnectorsStore | null {
  return store;
}

/** Test helper. */
export function resetConnectors(): void {
  uninstall?.();
  uninstall = null;
  store = null;
}
