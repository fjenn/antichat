import type {ModelView} from '../../../contracts';
import {unrestrictedPair} from '../naming';

const view = (id: string, extra: Partial<ModelView> = {}): ModelView => ({
  id,
  displayName: id,
  downloadBytes: 2e9,
  unrestricted: false,
  licenceName: 'Apache',
  openSource: true,
  recommended: false,
  supported: true,
  vision: false,
  fit: 'great',
  state: {status: 'not_installed'},
  ...extra,
});

describe('unrestricted switch', () => {
  const base = view('gemma', {state: {status: 'loaded'} as never});
  const unr = view('gemma-unr', {unrestricted: true, baseModel: 'gemma'});

  it('pairs the model in use with its unrestricted counterpart', () => {
    expect(unrestrictedPair([base, unr], 'gemma')).toMatchObject({
      target: {id: 'gemma-unr'},
      on: false,
    });
  });

  it('pairs an unrestricted model in use with its base', () => {
    expect(unrestrictedPair([base, unr], 'gemma-unr')).toMatchObject({
      target: {id: 'gemma'},
      on: true,
    });
  });

  it('offers no switch when the counterpart does not fit or does not exist', () => {
    const tooBig = {...unr, fit: 'too_large' as const};
    expect(unrestrictedPair([base, tooBig], 'gemma')).toBeNull();
    expect(unrestrictedPair([base], 'gemma')).toBeNull();
    expect(unrestrictedPair([base, unr], null)).toBeNull();
  });
});
