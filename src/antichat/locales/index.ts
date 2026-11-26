/**
 * AntiChat's own strings. English is the source; other locales are added as
 * JSON files with the same keys and registered in `catalogs`. Upstream's
 * `src/locales` stays untouched and unused by our screens.
 */
import {useCallback, useSyncExternalStore} from 'react';
import {I18nManager} from 'react-native';

import shell from './en.json';
// M6's strings live in their own file so milestones do not collide in one.
import m6 from './en.m6.json';

const en = {...shell, ...m6};

export type Messages = typeof en;

type Leaves<T, Prefix extends string = ''> = {
  [K in keyof T & string]: T[K] extends string
    ? `${Prefix}${K}`
    : Leaves<T[K], `${Prefix}${K}.`>;
}[keyof T & string];

export type MessageKey = Leaves<Messages>;
export type MessageParams = Record<string, string | number>;

type DeepPartial<T> = {[K in keyof T]?: DeepPartial<T[K]>};

const catalogs: Record<string, DeepPartial<Messages>> = {en};

let locale = 'en';
const listeners = new Set<() => void>();

function lookup(catalog: unknown, key: string): string | undefined {
  let node: unknown = catalog;
  for (const part of key.split('.')) {
    if (node === null || typeof node !== 'object') {
      return undefined;
    }
    node = (node as Record<string, unknown>)[part];
  }
  return typeof node === 'string' ? node : undefined;
}

/** A string in the current locale; English when the locale lacks the key. */
export function translate(key: MessageKey, params?: MessageParams): string {
  const template = lookup(catalogs[locale], key) ?? lookup(en, key) ?? key;
  if (!params) {
    return template;
  }
  return template.replace(/\{\{(\w+)\}\}/g, (match, name: string) =>
    name in params ? String(params[name]) : match,
  );
}

export function registerLocale(
  tag: string,
  messages: DeepPartial<Messages>,
): void {
  catalogs[tag] = messages;
}

/** Picks the best registered catalog for a BCP-47 tag ("de-AT" → "de"). */
export function setLocale(tag: string): void {
  const base = tag.split(/[-_]/)[0];
  const next = catalogs[tag] ? tag : catalogs[base] ? base : 'en';
  if (next !== locale) {
    locale = next;
    listeners.forEach(listener => listener());
  }
}

export function getLocale(): string {
  return locale;
}

/** Tags of the languages the app has strings for; English first. */
export function availableLocales(): string[] {
  return Object.keys(catalogs);
}

/** True when the layout runs right to left. Layouts use start/end, not left/right. */
export function isRTL(): boolean {
  return I18nManager.isRTL;
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export type Translate = typeof translate;

/** `const t = useT(); t('shell.newChat')`. Re-renders when the locale changes. */
export function useT(): Translate {
  const current = useSyncExternalStore(subscribe, getLocale, getLocale);
  return useCallback<Translate>(
    (key, params) => translate(key, params),
    // The locale is the cache key.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [current],
  );
}
