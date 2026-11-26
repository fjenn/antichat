/** The one coordinator of the app. */
import {getPorts} from '../../adapters';
import {ModelCoordinator} from './coordinator';

let shared: ModelCoordinator | null = null;
let readyListener: ((modelName: string, modelId: string) => void) | null = null;

/** The app's coordinator, on the app's ports. Built on first use. */
export function modelCoordinator(): ModelCoordinator {
  if (!shared) {
    const ports = getPorts();
    let start: (() => Promise<void>) | undefined;
    let freeStorageBytes: (() => Promise<number>) | undefined;
    // The runtime behind the port: the real one (`installEngine()` starts
    // the same instance), or the scripted one in tests and UI work.
    for (const find of [
      () => require('../../adapters/model').sharedModelRuntime(),
      () => require('./runtime').modelRuntime(),
    ]) {
      try {
        const runtime = find();
        if ((runtime.engine as unknown) === ports.model) {
          start = () => runtime.start();
          freeStorageBytes = async () =>
            (await runtime.backend.freeStorageBytes()) ?? 0;
          break;
        }
      } catch {
        // Not this one.
      }
    }
    shared = new ModelCoordinator({
      model: ports.model,
      connectivity: ports.connectivity,
      start,
      freeStorageBytes,
      onReady: model => readyListener?.(model.displayName, model.id),
    });
  }
  return shared;
}

/** First run registers here to announce "ready" (notification, haptic). */
export function onFirstModelReady(
  listener: ((modelName: string, modelId: string) => void) | null,
): void {
  readyListener = listener;
}

/** Tests: replace or drop the shared coordinator. */
export function setModelCoordinator(next: ModelCoordinator | null): void {
  shared?.dispose();
  shared = next;
}
