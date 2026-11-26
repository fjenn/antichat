import {bundledCatalog} from '../catalog/bundledCatalog';
import {getClass, getModel} from '../catalog/lookup';
import type {CatalogModel} from '../catalog/types';
import type {DeviceProfile} from '../device/types';
import {bestShapeFor, selectModel} from '../policy/select';
import {storeFit} from '../policy/storeFit';

import {PHONE} from './fixtures/devices';

const catalog = bundledCatalog;
const model = (id: string) => getModel(catalog, id) as CatalogModel;

function fitOn(phone: DeviceProfile, id: string) {
  const m = model(id);
  const vision = getClass(catalog, phone.deviceClass).features.vision;
  return storeFit(m, phone, catalog, bestShapeFor(m, phone, catalog, vision));
}

describe('store fit labels', () => {
  it('rates the automatic pick as running great', () => {
    for (const phone of [PHONE.A(), PHONE.C(), PHONE.D(), PHONE.E()]) {
      const pick = selectModel(phone, catalog);
      expect(storeFit(pick.model, phone, catalog, pick).level).toBe('great');
    }
  });

  it('greys out models that do not fit, with the memory they need', () => {
    const small = PHONE.A();
    expect(fitOn(small, 'qwen3.5-9b')).toEqual({
      level: 'too_large',
      needsRamGb: 16,
    });
    expect(fitOn(small, 'lfm3-1.7b').level).toBe('great');
  });

  it('calls a model sized for a bigger phone OK when it still loads', () => {
    const big = PHONE.DRaised();
    expect(fitOn(big, 'qwen3.5-9b').level).toBe('ok');
  });

  it('keeps unrestricted models from phones under 8 GB', () => {
    expect(fitOn(PHONE.B(), 'qwen3.5-4b-unrestricted')).toEqual({
      level: 'too_large',
      needsRamGb: 8,
    });
    expect(fitOn(PHONE.C(), 'qwen3.5-4b-unrestricted').level).not.toBe(
      'too_large',
    );
  });

  it('lists every new store model with a verified file and a summary', () => {
    for (const m of catalog.models) {
      expect(m.summary).toBeTruthy();
      for (const f of m.files) {
        expect(f.sha256).toMatch(/^[0-9a-f]{64}$/);
        expect(f.revision).toMatch(/^[0-9a-f]{40}$/);
      }
    }
  });

  it('gives every unrestricted model a standard base of the same size', () => {
    for (const m of catalog.models.filter(x => x.unrestricted)) {
      const base = getModel(catalog, m.baseModel ?? '');
      expect(base).toBeDefined();
      expect(base!.unrestricted).toBe(false);
      expect(base!.params).toBe(m.params);
    }
  });

  it('offers Gemma 4 12B on the phones that fit it, and more models on bigger phones', () => {
    expect(model('gemma-4-12b-qat').heldBack).toBeFalsy();
    expect(fitOn(PHONE.E(), 'gemma-4-12b-qat').level).not.toBe('too_large');
    expect(fitOn(PHONE.DRaised(), 'gemma-4-12b-qat').level).not.toBe(
      'too_large',
    );
    expect(fitOn(PHONE.C(), 'gemma-4-12b-qat').level).toBe('too_large');
    const fitting = (phone: DeviceProfile) =>
      catalog.models.filter(m => fitOn(phone, m.id).level !== 'too_large')
        .length;
    const counts = [PHONE.A(), PHONE.C(), PHONE.D(), PHONE.E()].map(fitting);
    expect([...counts].sort((a, b) => a - b)).toEqual(counts);
  });
});
