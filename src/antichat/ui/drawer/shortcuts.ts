/**
 * The shortcut rows at the top of the drawer (Images, Projects, …). A
 * milestone that builds one of them registers it here; until then the row
 * does not exist, so the drawer never shows a dead entry.
 *
 *   registerDrawerShortcut({
 *     id: 'images', order: 10, title: () => t('images.title'), icon: 'image',
 *     onPress: navigation => navigation.navigate('Main', {screen: 'Images'}),
 *   });
 */
import type {DrawerContentComponentProps} from '@react-navigation/drawer';

import type {IconName} from '../primitives';

type DrawerNavigationHelpers = DrawerContentComponentProps['navigation'];

export interface DrawerShortcut {
  id: string;
  /** Lower comes first. Images 10, Projects 20, leave gaps. */
  order: number;
  title: () => string;
  icon: IconName;
  /** Hide on phones that cannot do it (no image model, …). */
  available?: () => boolean;
  onPress: (navigation: DrawerNavigationHelpers) => void;
}

const shortcuts = new Map<string, DrawerShortcut>();
const listeners = new Set<() => void>();
let snapshot: readonly DrawerShortcut[] = [];

function publish(): void {
  snapshot = [...shortcuts.values()]
    .filter(shortcut => shortcut.available?.() ?? true)
    .sort((a, b) => a.order - b.order);
  listeners.forEach(listener => listener());
}

/** Adds (or replaces) a shortcut; returns a function that removes it. */
export function registerDrawerShortcut(shortcut: DrawerShortcut): () => void {
  shortcuts.set(shortcut.id, shortcut);
  publish();
  return () => {
    if (shortcuts.get(shortcut.id) === shortcut) {
      shortcuts.delete(shortcut.id);
      publish();
    }
  };
}

/** Call when something `available()` depends on has changed. */
export function refreshDrawerShortcuts(): void {
  publish();
}

export function drawerShortcuts(): readonly DrawerShortcut[] {
  return snapshot;
}

export function subscribeDrawerShortcuts(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}
