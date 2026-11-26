import en from '../en.json';
import {getLocale, registerLocale, setLocale, translate} from '..';

function leaves(node: unknown, prefix = ''): Array<[string, unknown]> {
  if (node !== null && typeof node === 'object') {
    return Object.entries(node).flatMap(([key, value]) =>
      leaves(value, prefix ? `${prefix}.${key}` : key),
    );
  }
  return [[prefix, node]];
}

describe('locales', () => {
  afterEach(() => setLocale('en'));

  it('has only non-empty strings in the English source', () => {
    for (const [key, value] of leaves(en)) {
      expect(typeof value === 'string' && value.trim().length > 0).toBe(true);
      // Catches a key left as its own value.
      expect(value).not.toBe(key);
    }
  });

  it('fills parameters', () => {
    expect(translate('shell.modelMenu', {name: 'AntiChat'})).toBe(
      'Model: AntiChat',
    );
    expect(translate('shell.modelMenu')).toBe('Model: {{name}}');
  });

  it('falls back to English for a key a locale lacks', () => {
    registerLocale('de', {shell: {newChat: 'Neuer Chat'}});
    setLocale('de-AT');
    expect(getLocale()).toBe('de');
    expect(translate('shell.newChat')).toBe('Neuer Chat');
    expect(translate('drawer.settings')).toBe('Settings');
    setLocale('xx');
    expect(getLocale()).toBe('en');
  });
});
