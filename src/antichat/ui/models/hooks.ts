import {useSyncExternalStore} from 'react';
import {autorun} from 'mobx';

import {getPorts, usePort} from '../../adapters';
import type {ModelPort} from '../../contracts';
import {modelCoordinator} from './shared';
import {lineup, type ModelLineup} from './naming';
import type {SetupStatus} from './setupStatus';

/** Re-render when the coordinator or its stored choices change. */
function useCoordinatorVersion(): void {
  useSyncExternalStore(subscribeCoordinator, getVersion, getVersion);
}

let version = 0;
const getVersion = () => version;

function subscribeCoordinator(notify: () => void): () => void {
  const coordinator = modelCoordinator();
  return autorun(() => {
    // Touch everything a screen may draw from.
    const {prefs} = coordinator;
    const watched = [
      coordinator.booted,
      coordinator.kickingOff,
      coordinator.celebrating,
      coordinator.freeVersion,
      prefs.loaded,
      prefs.started,
      prefs.selection,
      prefs.thinking,
      prefs.unrestrictedConsentAt,
      prefs.waitForWifi,
      prefs.userPaused,
      prefs.celebrated,
      prefs.notifyAsked,
      prefs.holdDownload,
    ];
    version += watched.length > 0 ? 1 : 0;
    notify();
  });
}

export interface ModelsSnapshot {
  port: ModelPort;
  models: ModelLineup;
  activeModelId: string | null;
}

/** The port, the named line-up and the active model, kept current. */
export function useModels(): ModelsSnapshot {
  const port = getPorts().model;
  useCoordinatorVersion();
  return usePort(port, current => ({
    port: current,
    models: lineup(current),
    activeModelId: current.activeModelId,
  }));
}

/** What the first-run card shows. */
export function useSetupStatus(): SetupStatus {
  useCoordinatorVersion();
  usePort(getPorts().connectivity, connectivity => connectivity.metered);
  return usePort(getPorts().model, () => modelCoordinator().status());
}

/** A model is loaded: the composer may send. */
export function useChatReady(): boolean {
  useCoordinatorVersion();
  return usePort(getPorts().model, () => modelCoordinator().chatReady);
}
