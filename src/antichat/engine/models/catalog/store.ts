import {
  passesMinAppVersion,
  toCoreVersion,
} from '../../../../services/deviceRules/appVersion';

import type {KeyValueStorage} from '../storage';

import {parseCatalog} from './parse';
import {Catalog} from './types';

/**
 * Remote catalogue updates.
 *
 * Design carried over from the Mac app: the catalogue is served as JSON with a
 * detached signature; the app keeps the bundled copy and the last good remote
 * copy, rejects rollbacks, and honours expiry and a minimum app version. Model
 * files themselves always come from Hugging Face and are checked against the
 * SHA-256 in the catalogue, so trusting the catalogue is what matters.
 */

/** Verifies a detached signature over the exact catalogue bytes. */
export interface CatalogSignatureVerifier {
  /**
   * @param payload the catalogue text exactly as fetched
   * @param signature the detached signature text as fetched (base64 Ed25519)
   * @returns true only if one of the pinned public keys signed the payload
   */
  verify(payload: string, signature: string): Promise<boolean>;
}

export interface FetchedText {
  status: number;
  text: string;
}

/** Network access, injected so tests and the offline app never touch it. */
export type FetchText = (url: string) => Promise<FetchedText>;

export type CatalogStorage = KeyValueStorage;

export interface CatalogStoreOptions {
  bundled: Catalog;
  storage: CatalogStorage;
  appVersion: string;
  /** Catalogue address; the signature is fetched from `${url}.sig`. */
  url?: string;
  fetchText?: FetchText;
  /** Without a verifier no remote catalogue is ever accepted. */
  verifier?: CatalogSignatureVerifier;
  now?: () => number;
  refreshIntervalMs?: number;
}

export type RefreshRejection =
  | 'not_configured'
  | 'network'
  | 'bad_signature'
  | 'invalid'
  | 'rollback'
  | 'expired'
  | 'app_too_old';

export type RefreshResult =
  | {status: 'updated'; serial: number}
  | {status: 'unchanged'; serial: number}
  | {status: 'rejected'; reason: RefreshRejection; detail?: string};

const KEY_PAYLOAD = 'antichat.catalog.lastGood';
const KEY_CHECKED = 'antichat.catalog.checkedAt';
const DAY_MS = 24 * 60 * 60 * 1000;

const isExpired = (catalog: Catalog, now: number): boolean => {
  if (catalog.expiresAt === null) {
    return false;
  }
  const at = Date.parse(catalog.expiresAt);
  // An unreadable date counts as expired: fail closed.
  return Number.isNaN(at) || at <= now;
};

// Fails closed: an unreadable minimum or app version rejects the catalogue.
const appIsNewEnough = (catalog: Catalog, appVersion: string): boolean =>
  passesMinAppVersion(catalog.minAppVersion, toCoreVersion(appVersion));

export class CatalogStore {
  private current: Catalog;
  private readonly now: () => number;

  constructor(private readonly options: CatalogStoreOptions) {
    this.current = options.bundled;
    this.now = options.now ?? Date.now;
  }

  /** The catalogue in force. Synchronous; starts as the bundled copy. */
  get catalog(): Catalog {
    return this.current;
  }

  /**
   * Restore the last accepted remote catalogue, if it is still valid and newer
   * than the bundled one. Never throws; any problem leaves the bundled copy.
   */
  async load(): Promise<Catalog> {
    const {bundled, storage, appVersion} = this.options;
    try {
      const saved = await storage.getItem(KEY_PAYLOAD);
      if (saved !== null) {
        const catalog = parseCatalog(JSON.parse(saved));
        const usable =
          catalog.serial > bundled.serial &&
          !isExpired(catalog, this.now()) &&
          appIsNewEnough(catalog, appVersion);
        if (usable) {
          this.current = catalog;
        } else {
          // Stale or superseded by an app update: drop it.
          this.current = bundled;
          await storage.removeItem(KEY_PAYLOAD);
        }
      }
    } catch {
      this.current = bundled;
    }
    return this.current;
  }

  /** True when the last successful check is older than the refresh interval. */
  async shouldRefresh(): Promise<boolean> {
    try {
      const raw = await this.options.storage.getItem(KEY_CHECKED);
      const checkedAt = raw === null ? NaN : Number(raw);
      const interval = this.options.refreshIntervalMs ?? DAY_MS;
      return !Number.isFinite(checkedAt) || this.now() - checkedAt >= interval;
    } catch {
      return true;
    }
  }

  /**
   * Fetch, verify and adopt a newer catalogue. Never throws: every failure is a
   * typed rejection and the catalogue in force stays as it was.
   */
  async refresh(): Promise<RefreshResult> {
    const {url, fetchText, verifier, storage, appVersion} = this.options;
    if (!url || !fetchText || !verifier) {
      return {status: 'rejected', reason: 'not_configured'};
    }

    let payload: string;
    let signature: string;
    try {
      const [doc, sig] = await Promise.all([
        fetchText(url),
        fetchText(`${url}.sig`),
      ]);
      if (doc.status !== 200 || sig.status !== 200) {
        return {
          status: 'rejected',
          reason: 'network',
          detail: `HTTP ${doc.status}/${sig.status}`,
        };
      }
      payload = doc.text;
      signature = sig.text.trim();
    } catch (error) {
      return {status: 'rejected', reason: 'network', detail: String(error)};
    }

    // Signature first: nothing unsigned is parsed.
    let signed = false;
    try {
      signed = await verifier.verify(payload, signature);
    } catch {
      signed = false;
    }
    if (!signed) {
      return {status: 'rejected', reason: 'bad_signature'};
    }

    let catalog: Catalog;
    try {
      catalog = parseCatalog(JSON.parse(payload));
    } catch (error) {
      return {status: 'rejected', reason: 'invalid', detail: String(error)};
    }

    if (catalog.serial < this.current.serial) {
      return {
        status: 'rejected',
        reason: 'rollback',
        detail: `serial ${catalog.serial} < ${this.current.serial}`,
      };
    }
    if (isExpired(catalog, this.now())) {
      return {status: 'rejected', reason: 'expired'};
    }
    if (!appIsNewEnough(catalog, appVersion)) {
      return {status: 'rejected', reason: 'app_too_old'};
    }

    await this.rememberCheck();
    if (catalog.serial === this.current.serial) {
      return {status: 'unchanged', serial: catalog.serial};
    }
    this.current = catalog;
    try {
      await storage.setItem(KEY_PAYLOAD, payload);
    } catch {
      // Still in force for this session; fetched again next launch.
    }
    return {status: 'updated', serial: catalog.serial};
  }

  private async rememberCheck(): Promise<void> {
    try {
      await this.options.storage.setItem(KEY_CHECKED, String(this.now()));
    } catch {
      // Only costs an extra check later.
    }
  }
}
