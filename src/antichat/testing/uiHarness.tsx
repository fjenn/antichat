/**
 * Helpers for screen tests: fake ports with a coordinator on them, and a
 * navigation double. Import `testing/setup` first in the test file.
 */
/* eslint-env jest */
import {createFakePorts, type FakePorts} from '../contracts/fakes';
import type {FakePortsOptions} from '../contracts/fakes';
import {setPorts} from '../adapters';
import {ModelCoordinator, setModelCoordinator} from '../ui/models';

export interface Harness {
  ports: FakePorts;
  coordinator: ModelCoordinator;
}

/** Fake ports become the app's ports, with a fresh coordinator on them. */
export async function mountHarness(
  options: FakePortsOptions & {started?: boolean} = {},
): Promise<Harness> {
  const ports = createFakePorts(options);
  setPorts(ports);
  const coordinator = new ModelCoordinator({
    model: ports.model,
    connectivity: ports.connectivity,
  });
  setModelCoordinator(coordinator);
  await coordinator.boot();
  if (options.started ?? !options.model?.fresh) {
    coordinator.prefs.set({started: true, celebrated: true});
  }
  return {ports, coordinator};
}

export function unmountHarness(): void {
  setModelCoordinator(null);
  setPorts();
}
