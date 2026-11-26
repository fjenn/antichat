/**
 * Where the signed catalogue comes from, and which keys may sign it.
 *
 * TODO(production key): `CATALOG_PUBLIC_KEYS` holds a PLACEHOLDER. Its private
 * half was thrown away when it was generated, so no remote catalogue can be
 * accepted until the real keys are pinned here. Before the first release:
 *   1. generate the mobile catalogue signing keys (two, kept apart from the
 *      Mac app's keys; see docs/research/06-antichat-mac-comparison.md),
 *   2. replace the placeholder below with their public halves,
 *   3. publish the catalogue and `catalog.json.sig` at `CATALOG_URL`.
 *
 * TODO(production URL): `CATALOG_URL` is the proposed address; nothing is
 * served there yet, so a refresh ends as a `network` rejection and the app
 * keeps the bundled catalogue.
 */
export const CATALOG_URL = 'https://antichat.ai/catalog/mobile/v1/catalog.json';

export const CATALOG_PUBLIC_KEYS: readonly string[] = [
  // PLACEHOLDER, not a production key (see the TODO above).
  'AepIpTovyTbKssl4IJmc1CL1Vf7hVBIi1UeEFMU5nr0=',
];

/** Model files are fetched from here: `<base>/<repo>/resolve/<revision>/<path>`. */
export const MODEL_FILES_BASE_URL = 'https://huggingface.co';
