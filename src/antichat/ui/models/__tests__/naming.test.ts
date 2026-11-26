import type {ModelState, ModelView} from '../../../contracts';
import {bundledCatalog} from '../../../engine/models/catalog/bundledCatalog';
import {isArriving, isInstalled, lineup, roleOf} from '../naming';

const GB = 1000 ** 3;

const view = (
  id: string,
  gb: number,
  extra: Partial<ModelView> = {},
): ModelView => ({
  id,
  displayName: id,
  downloadBytes: gb * GB,
  unrestricted: false,
  licenceName: 'Apache License 2.0',
  openSource: true,
  recommended: false,
  supported: true,
  vision: false,
  state: {status: 'not_installed'},
  ...extra,
});

describe('lineup', () => {
  const port = {
    unrestrictedModelId: 'open',
    models: [
      view('big', 5.2, {recommended: true}),
      view('tiny', 0.7),
      view('small', 1.1),
      view('nearly', 4.9),
      view('huge', 6.3),
      view('too-big', 9, {supported: false}),
      view('open', 5.3, {unrestricted: true}),
      view('other-open', 2.7, {unrestricted: true}),
    ],
  };
  const models = lineup(port);

  it('calls the phone’s own model Smart', () => {
    expect(models.smart?.id).toBe('big');
    expect(roleOf('big', models)).toBe('smart');
  });

  it('offers the largest clearly smaller model as Fast', () => {
    expect(models.fast?.id).toBe('small');
  });

  it('offers the next larger model the phone can run as Smartest', () => {
    expect(models.smartest?.id).toBe('huge');
  });

  it('names only the phone’s own unrestricted add-on', () => {
    expect(models.unrestricted?.id).toBe('open');
    expect(roleOf('other-open', models)).toBe('other');
  });

  it('keeps everything else for experts, and drops what cannot run', () => {
    expect(models.others.map(model => model.id).sort()).toEqual([
      'nearly',
      'other-open',
      'tiny',
    ]);
  });

  it('has no Fast on a phone whose model is already the smallest', () => {
    const only = lineup({
      unrestrictedModelId: null,
      models: [view('a', 1.1, {recommended: true}), view('b', 1.1)],
    });
    expect(only.fast).toBeUndefined();
    expect(only.smartest).toBeUndefined();
    expect(only.unrestricted).toBeUndefined();
  });

  it('gives every catalogue model a distinct plain role per class', () => {
    // A sanity check against the real catalogue: at most one of each role.
    const sizes = new Map(
      bundledCatalog.models.map(model => [model.id, model.files[0].sizeBytes]),
    );
    for (const cls of bundledCatalog.classes) {
      const made = lineup({
        unrestrictedModelId: cls.unrestrictedModel,
        models: bundledCatalog.models.map(model =>
          view(model.id, (sizes.get(model.id) as number) / GB, {
            recommended: model.id === cls.defaultModel,
            unrestricted: model.unrestricted,
          }),
        ),
      });
      expect(made.smart?.id).toBe(cls.defaultModel);
      const named = [made.smart, made.fast, made.smartest, made.unrestricted]
        .filter(Boolean)
        .map(model => model!.id);
      expect(new Set(named).size).toBe(named.length);
    }
  });
});

describe('installed and arriving', () => {
  const withState = (state: ModelState) => view('m', 1, {state});
  const progress = {receivedBytes: 1, totalBytes: 2, fraction: 0.5};

  it('counts a loaded, loading or ready model as installed', () => {
    expect(isInstalled(withState({status: 'ready'}))).toBe(true);
    expect(isInstalled(withState({status: 'loading'}))).toBe(true);
    expect(
      isInstalled(
        withState({
          status: 'failed',
          reason: 'load_failed',
          stage: 'load',
          retryable: true,
          resumeTo: 'ready',
        }),
      ),
    ).toBe(true);
  });

  it('does not count a download as installed', () => {
    const downloading = withState({
      status: 'downloading',
      paused: false,
      progress,
    });
    expect(isInstalled(downloading)).toBe(false);
    expect(isArriving(downloading)).toBe(true);
    expect(isArriving(withState({status: 'verifying', fraction: 0.5}))).toBe(
      true,
    );
    expect(isArriving(withState({status: 'not_installed'}))).toBe(false);
  });
});
