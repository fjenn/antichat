import appPackage from '../../../../../package.json';
import {
  findLicencePackage,
  licencePackages,
  licenceText,
  packageKey,
  searchPackages,
} from '../about/packages';

describe('open-source licences', () => {
  const packages = licencePackages();
  const names = new Set(packages.map(item => item.name));

  it('lists every direct dependency of the app', () => {
    // Fails after a dependency change until
    // `node tools/antichat/generate-licences.mjs` is run again.
    const missing = Object.keys(appPackage.dependencies).filter(
      name => !names.has(name),
    );
    expect(missing).toEqual([]);
  });

  it('includes what the direct dependencies depend on', () => {
    expect(packages.length).toBeGreaterThan(
      Object.keys(appPackage.dependencies).length * 2,
    );
    expect(packages.filter(item => item.direct).length).toBeGreaterThan(50);
  });

  it('names a licence for every package', () => {
    for (const item of packages) {
      expect(item.licence.length).toBeGreaterThan(0);
      expect(item.version).toMatch(/^\d/);
    }
  });

  it('has the licence text for the libraries the app is built on', () => {
    for (const name of ['react-native', 'llama.rn', 'mobx', 'fflate']) {
      const item = packages.find(candidate => candidate.name === name)!;
      expect(item).toBeDefined();
      expect(licenceText(item).length).toBeGreaterThan(200);
    }
  });

  it('is sorted and finds a package by key', () => {
    const sorted = [...packages].sort((a, b) =>
      a.name.localeCompare(b.name, 'en'),
    );
    expect(packages.map(item => item.name)).toEqual(
      sorted.map(item => item.name),
    );
    const first = packages[0];
    expect(findLicencePackage(packageKey(first))).toBe(first);
    expect(findLicencePackage('nope@0')).toBeUndefined();
  });

  it('searches by name and by licence', () => {
    expect(
      searchPackages(packages, 'mobx').every(item =>
        item.name.includes('mobx'),
      ),
    ).toBe(true);
    expect(searchPackages(packages, 'apache').length).toBeGreaterThan(5);
    expect(searchPackages(packages, '  ')).toBe(packages);
    expect(searchPackages(packages, 'no-such-package-xyz')).toEqual([]);
  });
});
