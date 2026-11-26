import raw from '../catalog/bundled.json';
import {bundledCatalog} from '../catalog/bundledCatalog';
import {
  CatalogSignatureVerifier,
  CatalogStore,
  CatalogStoreOptions,
  FetchText,
} from '../catalog/store';
import {MemoryStorage} from '../storage';

const URL = 'https://example.test/catalog/mobile/v1/catalog.json';
const NOW = Date.parse('2026-12-01T00:00:00Z');

const remoteDoc = (changes: Record<string, unknown> = {}): string =>
  JSON.stringify({
    ...raw,
    serial: bundledCatalog.serial + 1,
    expiresAt: '2027-03-01T00:00:00Z',
    ...changes,
  });

const serving =
  (payload: string, signature = 'good-signature'): FetchText =>
  async url =>
    url.endsWith('.sig')
      ? {status: 200, text: `${signature}\n`}
      : {status: 200, text: payload};

/** Accepts exactly the signature "good-signature". */
const verifier: CatalogSignatureVerifier = {
  verify: jest.fn(
    async (_payload, signature) => signature === 'good-signature',
  ),
};

function makeStore(overrides: Partial<CatalogStoreOptions> = {}) {
  const storage = new MemoryStorage();
  const store = new CatalogStore({
    bundled: bundledCatalog,
    storage,
    appVersion: '1.2.0',
    url: URL,
    fetchText: serving(remoteDoc()),
    verifier,
    now: () => NOW,
    ...overrides,
  });
  return {store, storage: (overrides.storage as MemoryStorage) ?? storage};
}

describe('CatalogStore', () => {
  it('starts on the bundled catalogue', async () => {
    const {store} = makeStore();
    expect(store.catalog).toBe(bundledCatalog);
    expect(await store.load()).toBe(bundledCatalog);
  });

  it('adopts a signed newer catalogue and keeps it across restarts', async () => {
    const {store, storage} = makeStore();
    expect(await store.refresh()).toEqual({
      status: 'updated',
      serial: bundledCatalog.serial + 1,
    });
    expect(store.catalog.serial).toBe(bundledCatalog.serial + 1);

    const restarted = makeStore({storage, fetchText: undefined}).store;
    expect((await restarted.load()).serial).toBe(bundledCatalog.serial + 1);
  });

  it('verifies the exact bytes that were fetched', async () => {
    const payload = remoteDoc();
    const spy = jest.fn(async () => true);
    const {store} = makeStore({
      fetchText: serving(payload),
      verifier: {verify: spy},
    });
    await store.refresh();
    expect(spy).toHaveBeenCalledWith(payload, 'good-signature');
  });

  it('rejects a bad signature before parsing anything', async () => {
    const {store, storage} = makeStore({
      fetchText: serving('this is not even JSON', 'forged'),
    });
    expect(await store.refresh()).toEqual({
      status: 'rejected',
      reason: 'bad_signature',
    });
    expect(store.catalog).toBe(bundledCatalog);
    expect(await storage.getItem('antichat.catalog.lastGood')).toBeNull();
  });

  it('treats a throwing verifier as a bad signature', async () => {
    const {store} = makeStore({
      verifier: {
        verify: async () => {
          throw new Error('crypto unavailable');
        },
      },
    });
    expect(await store.refresh()).toMatchObject({reason: 'bad_signature'});
  });

  it('accepts nothing without a verifier, a fetcher or an address', async () => {
    for (const missing of ['verifier', 'fetchText', 'url'] as const) {
      const {store} = makeStore({[missing]: undefined});
      expect(await store.refresh()).toEqual({
        status: 'rejected',
        reason: 'not_configured',
      });
    }
  });

  it('rejects a signed but invalid document', async () => {
    const {store} = makeStore({fetchText: serving(remoteDoc({ladder: []}))});
    expect(await store.refresh()).toMatchObject({
      status: 'rejected',
      reason: 'invalid',
    });
    expect(store.catalog).toBe(bundledCatalog);
  });

  it('rejects a rollback to an older serial', async () => {
    const {store} = makeStore({
      fetchText: serving(remoteDoc({serial: bundledCatalog.serial - 1})),
    });
    expect(await store.refresh()).toMatchObject({
      status: 'rejected',
      reason: 'rollback',
    });
  });

  it('rejects a rollback below an already adopted remote copy', async () => {
    const {store, storage} = makeStore({
      fetchText: serving(remoteDoc({serial: bundledCatalog.serial + 5})),
    });
    await store.refresh();
    const later = new CatalogStore({
      bundled: bundledCatalog,
      storage,
      appVersion: '1.2.0',
      url: URL,
      verifier,
      now: () => NOW,
      fetchText: serving(remoteDoc({serial: bundledCatalog.serial + 2})),
    });
    await later.load();
    expect(await later.refresh()).toMatchObject({reason: 'rollback'});
    expect(later.catalog.serial).toBe(bundledCatalog.serial + 5);
  });

  it('reports the same serial as unchanged', async () => {
    const {store} = makeStore({
      fetchText: serving(remoteDoc({serial: bundledCatalog.serial})),
    });
    expect(await store.refresh()).toEqual({
      status: 'unchanged',
      serial: bundledCatalog.serial,
    });
  });

  it('rejects an expired catalogue, and one with an unreadable expiry', async () => {
    for (const expiresAt of ['2026-11-30T00:00:00Z', 'soon']) {
      const {store} = makeStore({fetchText: serving(remoteDoc({expiresAt}))});
      expect(await store.refresh()).toMatchObject({reason: 'expired'});
    }
  });

  it('rejects a catalogue that needs a newer app', async () => {
    const {store} = makeStore({
      fetchText: serving(remoteDoc({minAppVersion: '9.0.0'})),
    });
    expect(await store.refresh()).toMatchObject({reason: 'app_too_old'});
  });

  it('reports HTTP and network failures without changing anything', async () => {
    const notFound = makeStore({
      fetchText: async () => ({status: 404, text: ''}),
    }).store;
    expect(await notFound.refresh()).toMatchObject({
      reason: 'network',
      detail: 'HTTP 404/404',
    });
    const offline = makeStore({
      fetchText: async () => {
        throw new Error('no route');
      },
    }).store;
    expect(await offline.refresh()).toMatchObject({reason: 'network'});
    expect(offline.catalog).toBe(bundledCatalog);
  });

  it('drops a saved copy once it has expired', async () => {
    const {store, storage} = makeStore();
    await store.refresh();
    const later = makeStore({
      storage,
      now: () => Date.parse('2027-06-01T00:00:00Z'),
    }).store;
    expect(await later.load()).toBe(bundledCatalog);
    expect(await storage.getItem('antichat.catalog.lastGood')).toBeNull();
  });

  it('drops a saved copy the bundled catalogue has overtaken', async () => {
    const {store, storage} = makeStore();
    await store.refresh();
    const newerApp = new CatalogStore({
      bundled: {...bundledCatalog, serial: bundledCatalog.serial + 10},
      storage,
      appVersion: '2.0.0',
      now: () => NOW,
    });
    expect((await newerApp.load()).serial).toBe(bundledCatalog.serial + 10);
  });

  it('survives corrupt saved data and failing storage', async () => {
    const storage = new MemoryStorage();
    await storage.setItem('antichat.catalog.lastGood', '{broken');
    expect(await makeStore({storage}).store.load()).toBe(bundledCatalog);

    const failing = {
      getItem: async () => {
        throw new Error('disk');
      },
      setItem: async () => {
        throw new Error('disk');
      },
      removeItem: async () => undefined,
    };
    const {store} = makeStore({storage: failing as any});
    expect(await store.load()).toBe(bundledCatalog);
    expect(await store.shouldRefresh()).toBe(true);
    // Still adopted for this session even though it cannot be saved.
    expect(await store.refresh()).toMatchObject({status: 'updated'});
  });

  it('refreshes once a day', async () => {
    let now = NOW;
    const {store} = makeStore({now: () => now});
    expect(await store.shouldRefresh()).toBe(true);
    await store.refresh();
    expect(await store.shouldRefresh()).toBe(false);
    now += 23 * 60 * 60 * 1000;
    expect(await store.shouldRefresh()).toBe(false);
    now += 2 * 60 * 60 * 1000;
    expect(await store.shouldRefresh()).toBe(true);
  });

  it('does not count a failed check as a check', async () => {
    const {store} = makeStore({fetchText: serving(remoteDoc(), 'forged')});
    await store.refresh();
    expect(await store.shouldRefresh()).toBe(true);
  });
});
