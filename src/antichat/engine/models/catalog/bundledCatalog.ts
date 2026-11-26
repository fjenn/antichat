import raw from './bundled.json';
import {parseCatalog} from './parse';
import {Catalog} from './types';

/**
 * The catalogue shipped inside the app.
 *
 * This file must not be called `bundled.ts`: Metro tries `.json` before `.ts`,
 * so `import ... from './bundled'` would resolve to `bundled.json` and
 * `bundledCatalog` would be undefined in the app (Jest resolves `.ts` first
 * and would not notice). It is the floor: the app always has a
 * working model list, with no network and before any update.
 */
export const bundledCatalog: Catalog = parseCatalog(raw);
