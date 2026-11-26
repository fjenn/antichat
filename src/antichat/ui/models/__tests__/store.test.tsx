import '../../../testing/setup';

import React, {createRef} from 'react';
import {act, fireEvent, render, screen} from '@testing-library/react-native';
import {GestureHandlerRootView} from 'react-native-gesture-handler';

import type {ModelView} from '../../../contracts';
import {ModelDetailsSheet} from '../ModelDetailsSheet';
import {ModelRow} from '../ModelRow';
import type {SheetHandle} from '../../primitives';
import {storeSections} from '../naming';

function view(id: string, extra: Partial<ModelView> = {}): ModelView {
  return {
    id,
    displayName: id,
    downloadBytes: 2e9,
    unrestricted: false,
    licenceName: 'Apache License 2.0',
    openSource: true,
    recommended: false,
    supported: true,
    vision: false,
    state: {status: 'not_installed'},
    fit: 'great',
    ...extra,
  };
}

describe('model store', () => {
  it('leaves held-back models out unless they are installed', () => {
    const pick = view('pick', {recommended: true});
    const held = view('held', {heldBack: true, downloadBytes: 6e9});
    const heldHere = view('held-here', {
      heldBack: true,
      downloadBytes: 7e9,
      state: {status: 'ready'},
    });
    const ids = (s: ReturnType<typeof storeSections>) =>
      [...s.recommended, ...s.faster, ...s.smarter, ...s.unrestricted].map(
        m => m.id,
      );
    expect(ids(storeSections({models: [pick, held, heldHere]}))).toEqual([
      'pick',
      'held-here',
    ]);
  });

  it('offers only what this phone can run, plus anything already on it', () => {
    const pick = view('pick', {recommended: true});
    const big = view('big', {fit: 'too_large', downloadBytes: 9e9});
    const bigHere = view('big-here', {
      fit: 'too_large',
      downloadBytes: 8e9,
      state: {status: 'ready'},
    });
    const s = storeSections({models: [pick, big, bigHere]});
    expect(
      [...s.recommended, ...s.faster, ...s.smarter, ...s.unrestricted].map(
        m => m.id,
      ),
    ).toEqual(['pick', 'big-here']);
  });

  it('shows an installed model that is too large as installed, with a warning', () => {
    const model = view('big', {
      fit: 'too_large',
      needsRamGb: 16,
      supported: false,
      state: {status: 'ready'},
    });
    render(
      <GestureHandlerRootView>
        <ModelRow
          model={model}
          name="Big"
          tagline=""
          role="other"
          inUse={false}
          description="Large."
          onAction={() => {}}
        />
      </GestureHandlerRootView>,
    );
    expect(screen.getByTestId('model-line-big').props.children).toBe(
      'May be slow or close on this phone · 2 GB',
    );
    expect(screen.queryByText(/Too large/)).toBeNull();
    expect(screen.queryByTestId('model-download-big')).toBeNull();
  });

  it('greys a model that is too large and not installed', () => {
    render(
      <ModelRow
        model={view('big', {
          fit: 'too_large',
          needsRamGb: 16,
          supported: false,
        })}
        name="Big"
        tagline=""
        role="other"
        inUse={false}
        description="Large."
        onAction={() => {}}
      />,
    );
    expect(
      screen.getByText('Too large for this phone · needs 16 GB · 2 GB'),
    ).toBeTruthy();
    expect(screen.queryByTestId('model-download-big')).toBeNull();
  });

  it('tags a model with many languages as Multilingual on its card', () => {
    const row = (model: ModelView) => (
      <GestureHandlerRootView>
        <ModelRow
          model={model}
          name={model.id}
          tagline=""
          role="other"
          inUse={false}
          description="A model."
          onAction={() => {}}
        />
      </GestureHandlerRootView>
    );
    const many = view('many', {
      languages: {count: 140, atLeast: true, source: 'google/x'},
    });
    const few = view('few', {languages: {codes: ['en'], source: 'x/y'}});
    render(row(many));
    expect(screen.getByTestId('model-multilingual-many')).toBeTruthy();
    render(row(few));
    expect(screen.queryByTestId('model-multilingual-few')).toBeNull();
  });

  const details = async (model: ModelView) => {
    const ref = createRef<SheetHandle>();
    render(<ModelDetailsSheet ref={ref} model={model} />);
    await act(async () => ref.current?.present());
  };

  it('lists a short language list in Details', async () => {
    await details(
      view('few', {languages: {codes: ['nl', 'en'], source: 'x/y'}}),
    );
    expect(screen.getByText('English, Dutch')).toBeTruthy();
  });

  it('sums a long list up and expands it on tap', async () => {
    const codes = ['en', 'fr', 'es', 'de', 'it', 'pt', 'nl', 'zh', 'ja'];
    await details(view('many', {languages: {codes, source: 'x/y'}}));
    expect(screen.getByText('Multilingual (9 languages)')).toBeTruthy();
    expect(screen.queryByTestId('model-details-language-list')).toBeNull();
    fireEvent.press(screen.getByTestId('model-details-languages-toggle'));
    expect(
      screen.getByTestId('model-details-language-list').props.children,
    ).toBe(
      'English, French, Spanish, German, Italian, Portuguese, Dutch, Chinese, Japanese',
    );
  });

  it('shows a count when the card gives no list, and nothing when unknown', async () => {
    await details(
      view('qwen', {languages: {count: 201, source: 'Qwen/Qwen3.5-2B'}}),
    );
    expect(screen.getByText('Multilingual (201 languages)')).toBeTruthy();
    expect(screen.queryByTestId('model-details-languages-toggle')).toBeNull();
  });

  it('leaves the languages line out when the card says nothing', async () => {
    await details(view('unknown'));
    expect(screen.getByText('Download size')).toBeTruthy();
    expect(screen.queryByTestId('model-details-languages')).toBeNull();
  });
});
