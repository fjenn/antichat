import '../../../testing/setup';

import React from 'react';
import {Text} from 'react-native';
import {act, fireEvent, render, screen} from '@testing-library/react-native';

import {mountHarness, unmountHarness} from '../../../testing/uiHarness';
import {NeedsConnection, OfflineAnswerNote, OfflinePill} from '..';

describe('offline pieces', () => {
  afterEach(() => unmountHarness());

  it('shows the pill only while offline', async () => {
    const {ports} = await mountHarness();
    render(<OfflinePill />);
    expect(screen.queryByTestId('offline-pill')).toBeNull();
    act(() => ports.connectivity.set(false));
    expect(screen.getByText('Offline')).toBeTruthy();
    expect(screen.getByTestId('offline-pill').props.accessibilityLabel).toBe(
      'You’re offline. Chat still works.',
    );
    act(() => ports.connectivity.set(true));
    expect(screen.queryByTestId('offline-pill')).toBeNull();
  });

  it('greys an online-only control and says why', async () => {
    const {ports} = await mountHarness();
    render(
      <NeedsConnection testID="search">
        <Text>Search</Text>
      </NeedsConnection>,
    );
    expect(screen.queryByText('Needs a connection')).toBeNull();
    act(() => ports.connectivity.set(false));
    expect(screen.getByText('Needs a connection')).toBeTruthy();
    expect(screen.getByTestId('search').props.accessibilityState).toEqual({
      disabled: true,
    });
  });

  it('lets a search be retried only once the phone is online', async () => {
    const {ports} = await mountHarness();
    act(() => ports.connectivity.set(false));
    const onRetry = jest.fn();
    render(<OfflineAnswerNote onRetry={onRetry} />);
    const retry = screen.getByTestId('offline-answer-note-retry');
    expect(retry.props.accessibilityState).toEqual({disabled: true});
    fireEvent.press(retry);
    expect(onRetry).not.toHaveBeenCalled();
    act(() => ports.connectivity.set(true));
    fireEvent.press(screen.getByTestId('offline-answer-note-retry'));
    expect(onRetry).toHaveBeenCalledTimes(1);
  });
});
