/**
 * The open-source packages in the app. (Not named `licences.ts`: Metro
 * resolves `./licences` to the JSON file next to it.) The data is generated from the
 * dependency tree by `tools/antichat/generate-licences.mjs`; it is loaded
 * when the licences screen opens, not at launch.
 */
export interface LicencePackage {
  name: string;
  version: string;
  /** SPDX id or expression as the package declares it. */
  licence: string;
  url?: string;
  copyright?: string[];
  /** Key into `texts`. */
  text?: string;
  /** Listed in the app's own package.json. */
  direct?: boolean;
}

interface LicenceData {
  packages: LicencePackage[];
  texts: Record<string, string>;
}

let data: LicenceData | null = null;

function load(): LicenceData {
  data ??= require('./licences.json') as LicenceData;
  return data;
}

export function licencePackages(): LicencePackage[] {
  return load().packages;
}

export function findLicencePackage(key: string): LicencePackage | undefined {
  return load().packages.find(item => packageKey(item) === key);
}

export const packageKey = (item: LicencePackage): string =>
  `${item.name}@${item.version}`;

/** Copyright lines followed by the licence body; empty when none was shipped. */
export function licenceText(item: LicencePackage): string {
  const body = item.text ? load().texts[item.text] : undefined;
  return [...(item.copyright ?? []), body ? unwrap(body) : undefined]
    .filter(Boolean)
    .join('\n\n');
}

/**
 * Licence files are wrapped at 80 columns; on a phone that leaves ragged
 * half lines. Lines of one paragraph are joined; lists and indented blocks
 * keep their breaks.
 */
function unwrap(text: string): string {
  return text.replace(/([^\n])\n(?=[^\n\s\-*•\d(])/g, '$1 ');
}

export function searchPackages(
  packages: LicencePackage[],
  query: string,
): LicencePackage[] {
  const needle = query.trim().toLowerCase();
  if (!needle) {
    return packages;
  }
  return packages.filter(
    item =>
      item.name.toLowerCase().includes(needle) ||
      item.licence.toLowerCase().includes(needle),
  );
}
