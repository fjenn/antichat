/**
 * Which implementation the project screens talk to. The fake over the
 * contract port until an engine implementation is set with `setProjectsUi`.
 */
import {useSyncExternalStore} from 'react';
import type {ComponentType} from 'react';

import {getPorts} from '../../adapters';
import {createFakeProjectsUi} from './fakeProjectsUi';
import type {ProjectsUi} from './types';

let current: ProjectsUi | undefined;
let filesSection: ComponentType<{projectId: string}> | undefined;
const listeners = new Set<() => void>();

function emit(): void {
  listeners.forEach(listener => listener());
}

export function getProjectsUi(): ProjectsUi {
  current ??= createFakeProjectsUi(getPorts().conversations);
  return current;
}

/** Sets the implementation; no argument goes back to the fake. */
export function setProjectsUi(next?: ProjectsUi): void {
  current = next;
  emit();
}

/**
 * The files slot of the project page. M10 registers its own section (list
 * plus "add files") here; until then the page lists the file names.
 */
export function setProjectFilesSection(
  component?: ComponentType<{projectId: string}>,
): void {
  filesSection = component;
  emit();
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

export function useProjectsUi(): ProjectsUi {
  return useSyncExternalStore(subscribe, getProjectsUi, getProjectsUi);
}

const getFilesSection = () => filesSection;

export function useProjectFilesSection():
  | ComponentType<{projectId: string}>
  | undefined {
  return useSyncExternalStore(subscribe, getFilesSection, getFilesSection);
}
