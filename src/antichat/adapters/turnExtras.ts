/**
 * What tools leave beside an answer: the web sources it can cite, and the
 * Connect card of a connector that is not connected yet.
 *
 * The tool engine reports results as events while the model's turn runs;
 * the message they belong to exists as a row only once the turn is over.
 * This store collects them per turn and files them under the newest
 * assistant message when generation ends. Sources are kept (AsyncStorage,
 * newest 300 answers) so an old chat still shows them.
 */
import AsyncStorage from '@react-native-async-storage/async-storage';
import {reaction} from 'mobx';

import {chatSessionStore} from '../../store';
import type {CitationView} from '../contracts/chat';
import {newestMessage} from '../engine/prompt/postTurn';
import type {ConnectAppCard} from '../engine/tools/cards';
import {subscribeToolEvents} from '../engine/tools/events';

export interface TurnExtras {
  citations: CitationView[];
  connect?: ConnectAppCard;
}

const KEY = 'antichat.turnExtras.v1';
const KEEP = 300;
const EMPTY: TurnExtras = Object.freeze({citations: []}) as TurnExtras;

const byMessage = new Map<string, TurnExtras>();
const listeners = new Set<() => void>();
let pending: TurnExtras = {citations: []};
let started = false;

const emit = () => listeners.forEach(listener => listener());

const siteOf = (url: string): string => {
  const host = /^https?:\/\/([^/?#]+)/i.exec(url)?.[1] ?? url;
  return host.replace(/^www\./, '');
};

function save(): void {
  const entries = [...byMessage.entries()]
    .filter(([, extras]) => extras.citations.length > 0)
    .slice(-KEEP)
    .map(([id, extras]) => [id, extras.citations]);
  AsyncStorage.setItem(KEY, JSON.stringify(entries)).catch(() => undefined);
}

/** Called once by the app root (real backend only). */
export function startTurnExtras(): () => void {
  if (started) {
    return () => undefined;
  }
  started = true;
  AsyncStorage.getItem(KEY)
    .then(raw => {
      for (const [id, citations] of JSON.parse(raw ?? '[]') as Array<
        [string, CitationView[]]
      >) {
        if (!byMessage.has(id)) {
          byMessage.set(id, {citations});
        }
      }
      emit();
    })
    .catch(() => undefined);

  const offTools = subscribeToolEvents(event => {
    if (event.type !== 'result') {
      return;
    }
    for (const source of event.sources ?? []) {
      if (!pending.citations.some(known => known.url === source.url)) {
        pending.citations.push({
          id: `${event.callId}:${pending.citations.length}`,
          title: source.title || siteOf(source.url),
          url: source.url,
          source: source.site || siteOf(source.url),
        });
      }
    }
    const card = event.card as {type?: string} | undefined;
    if (card?.type === 'connect_app') {
      pending.connect = card as ConnectAppCard;
    }
  });

  const offGenerating = reaction(
    () => chatSessionStore.isGenerating,
    (generating, wasGenerating) => {
      if (generating) {
        pending = {citations: []};
        return;
      }
      if (!wasGenerating) {
        return;
      }
      const collected = pending;
      pending = {citations: []};
      if (collected.citations.length === 0 && !collected.connect) {
        return;
      }
      const session = chatSessionStore.sessions.find(
        item => item.id === chatSessionStore.activeSessionId,
      );
      const last = newestMessage(session?.messages);
      if (last && last.type === 'assistant_turn') {
        byMessage.set(last.id, collected);
        save();
        emit();
      }
    },
  );
  return () => {
    offTools();
    offGenerating();
    started = false;
  };
}

export function turnExtrasFor(messageId: string): TurnExtras {
  return byMessage.get(messageId) ?? EMPTY;
}

/** The Connect card was used or closed: it goes. */
export function clearConnectCard(messageId: string): void {
  const extras = byMessage.get(messageId);
  if (extras?.connect) {
    byMessage.set(messageId, {citations: extras.citations});
    emit();
  }
}

export function subscribeTurnExtras(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}
