import {autorun} from 'mobx';

import {netInfoSource, NetInfoStateLike, toReading} from '../netinfo';
import {ConnectivityStore} from '../store';
import type {ConnectivitySource, NetworkReading} from '../types';

const WIFI: NetworkReading = {connected: true, kind: 'wifi', expensive: false};
const CELL: NetworkReading = {
  connected: true,
  kind: 'cellular',
  expensive: true,
};
const NONE: NetworkReading = {connected: false, kind: 'none', expensive: false};

/** A source the test pushes readings into. */
function fakeSource(initial: NetworkReading | Error = WIFI) {
  const listeners = new Set<(reading: NetworkReading) => void>();
  const source: ConnectivitySource = {
    read: async () => {
      if (initial instanceof Error) {
        throw initial;
      }
      return initial;
    },
    subscribe: listener => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };
  return {
    source,
    push: (reading: NetworkReading) => listeners.forEach(l => l(reading)),
    listenerCount: () => listeners.size,
  };
}

async function started(initial: NetworkReading | Error = WIFI, options = {}) {
  const fake = fakeSource(initial);
  const store = new ConnectivityStore(fake.source, options);
  await store.start();
  return {...fake, store};
}

beforeEach(() => jest.useFakeTimers());
afterEach(() => jest.useRealTimers());

describe('ConnectivityStore', () => {
  it('is online before anything is known', () => {
    const store = new ConnectivityStore(fakeSource().source);
    expect(store.online).toBe(true);
    expect(store.metered).toBe(false);
    expect(store.kind).toBe('unknown');
  });

  it('applies the first reading at once', async () => {
    const offline = await started(NONE);
    expect(offline.store.online).toBe(false);
    expect(offline.store.kind).toBe('none');

    const cellular = await started(CELL);
    expect(cellular.store.status).toEqual({online: true, metered: true});
    expect(cellular.store.kind).toBe('cellular');
  });

  it('flips to offline within two seconds of airplane mode', async () => {
    const {store, push} = await started();
    push(NONE);
    expect(store.online).toBe(true);
    jest.advanceTimersByTime(999);
    expect(store.online).toBe(true);
    jest.advanceTimersByTime(1);
    expect(store.online).toBe(false);
    expect(store.kind).toBe('none');
  });

  it('ignores a short drop while hopping between networks', async () => {
    const {store, push} = await started();
    const listener = jest.fn();
    store.subscribe(listener);
    push(NONE);
    jest.advanceTimersByTime(400);
    push(CELL);
    jest.advanceTimersByTime(5000);
    expect(store.online).toBe(true);
    // The only visible change: the connection is now metered.
    expect(store.metered).toBe(true);
    expect(store.kind).toBe('cellular');
    expect(listener).toHaveBeenCalledTimes(1);
  });

  it('comes back online after a short hold', async () => {
    const {store, push} = await started(NONE);
    push(WIFI);
    expect(store.online).toBe(false);
    jest.advanceTimersByTime(300);
    expect(store.online).toBe(true);
    expect(store.kind).toBe('wifi');
  });

  it('does not come online for a connection that vanishes again', async () => {
    const {store, push} = await started(NONE);
    push(WIFI);
    jest.advanceTimersByTime(100);
    push(NONE);
    jest.advanceTimersByTime(5000);
    expect(store.online).toBe(false);
  });

  it('does not restart the delay on repeated identical events', async () => {
    const {store, push} = await started();
    push(NONE);
    jest.advanceTimersByTime(600);
    push(NONE);
    jest.advanceTimersByTime(400);
    expect(store.online).toBe(false);
  });

  it('updates the metered hint immediately', async () => {
    const {store, push} = await started();
    push(CELL);
    expect(store.metered).toBe(true);
    push(WIFI);
    expect(store.metered).toBe(false);
  });

  it('keeps the last metered hint while offline', async () => {
    const {store, push} = await started(CELL);
    push(NONE);
    jest.advanceTimersByTime(1000);
    expect(store.online).toBe(false);
    expect(store.metered).toBe(true);
  });

  it('honours custom delays', async () => {
    const {store, push} = await started(WIFI, {
      offlineDelayMs: 50,
      onlineDelayMs: 0,
    });
    push(NONE);
    jest.advanceTimersByTime(50);
    expect(store.online).toBe(false);
    push(WIFI);
    jest.advanceTimersByTime(0);
    expect(store.online).toBe(true);
  });

  it('notifies subscribers and MobX observers on a change of the flag', async () => {
    const {store, push} = await started();
    const listener = jest.fn();
    const unsubscribe = store.subscribe(listener);
    const seen: boolean[] = [];
    const stop = autorun(() => seen.push(store.online));

    push(NONE);
    expect(listener).not.toHaveBeenCalled();
    jest.advanceTimersByTime(1000);
    expect(listener).toHaveBeenCalledTimes(1);
    expect(seen).toEqual([true, false]);

    unsubscribe();
    push(WIFI);
    jest.advanceTimersByTime(300);
    expect(listener).toHaveBeenCalledTimes(1);
    expect(seen).toEqual([true, false, true]);
    stop();
  });

  it('says nothing when a reading changes nothing', async () => {
    const {store, push} = await started();
    const listener = jest.fn();
    store.subscribe(listener);
    push(WIFI);
    jest.advanceTimersByTime(5000);
    expect(listener).not.toHaveBeenCalled();
  });

  it('stays optimistic when the first read fails', async () => {
    const {store, push} = await started(new Error('no module'));
    expect(store.online).toBe(true);
    push(NONE);
    jest.advanceTimersByTime(1000);
    expect(store.online).toBe(false);
  });

  it('starts once and stops cleanly', async () => {
    const {store, push, listenerCount} = await started();
    await store.start();
    expect(listenerCount()).toBe(1);
    push(NONE);
    store.stop();
    expect(listenerCount()).toBe(0);
    jest.advanceTimersByTime(5000);
    // The pending flip was cancelled with the subscription.
    expect(store.online).toBe(true);
    store.stop();
  });
});

describe('NetInfo adapter', () => {
  const state = (over: Partial<NetInfoStateLike>): NetInfoStateLike => ({
    type: 'wifi',
    isConnected: true,
    isInternetReachable: true,
    details: {isConnectionExpensive: false},
    ...over,
  });

  it('maps connection types', () => {
    expect(toReading(state({}))).toEqual(WIFI);
    expect(toReading(state({type: 'ethernet'})).kind).toBe('wifi');
    expect(toReading(state({type: 'cellular'}))).toEqual(CELL);
    expect(toReading(state({type: 'vpn'})).kind).toBe('other');
    expect(toReading(state({type: 'unknown'})).kind).toBe('unknown');
  });

  it('is offline only on an explicit "no"', () => {
    expect(toReading(state({type: 'none', isConnected: false}))).toEqual(NONE);
    expect(toReading(state({isConnected: false})).connected).toBe(false);
    // Wi-Fi without internet (captive portal).
    expect(toReading(state({isInternetReachable: false})).connected).toBe(
      false,
    );
    // Not determined yet at launch.
    expect(
      toReading(state({isConnected: null, isInternetReachable: null}))
        .connected,
    ).toBe(true);
    expect(toReading({type: 'unknown', isConnected: null}).connected).toBe(
      true,
    );
  });

  it('treats cellular and expensive Wi-Fi (hotspot) as metered', () => {
    expect(toReading(state({type: 'cellular', details: null})).expensive).toBe(
      true,
    );
    expect(
      toReading(state({details: {isConnectionExpensive: true}})).expensive,
    ).toBe(true);
    expect(toReading(state({details: undefined})).expensive).toBe(false);
  });

  it('wraps the module as a source', async () => {
    let handler: (s: NetInfoStateLike) => void = () => undefined;
    const remove = jest.fn();
    const netInfo = {
      fetch: jest.fn(async () => state({type: 'cellular'})),
      addEventListener: jest.fn((listener: (s: NetInfoStateLike) => void) => {
        handler = listener;
        return remove;
      }),
    };
    const store = new ConnectivityStore(netInfoSource(netInfo));
    await store.start();
    expect(store.metered).toBe(true);
    handler(state({type: 'none', isConnected: false}));
    jest.advanceTimersByTime(1000);
    expect(store.online).toBe(false);
    store.stop();
    expect(remove).toHaveBeenCalled();
  });
});
