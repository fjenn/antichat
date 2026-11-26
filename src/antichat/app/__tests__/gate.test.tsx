import '../../testing/setup';

import React from 'react';
import {Text} from 'react-native';
import AsyncStorage from '@react-native-async-storage/async-storage';
import {render, screen, waitFor} from '@testing-library/react-native';

import {AntiChatGate} from '../AntiChatGate';

jest.mock('../AntiChatApp', () => ({
  AntiChatApp: () => {
    const {Text: MockText} = require('react-native');
    return <MockText>antichat shell</MockText>;
  },
}));

const Upstream = () => <Text>upstream app</Text>;

describe('AntiChatGate', () => {
  beforeEach(() => AsyncStorage.clear());

  it('shows the AntiChat shell by default, after preferences are loaded', async () => {
    render(<AntiChatGate upstream={Upstream} />);
    // Nothing is drawn before the stored theme is known.
    expect(screen.queryByText('antichat shell')).toBeNull();
    await waitFor(() =>
      expect(screen.getByText('antichat shell')).toBeTruthy(),
    );
    expect(screen.queryByText('upstream app')).toBeNull();
  });

  it('shows upstream when a debug build asked for it', async () => {
    await AsyncStorage.setItem('antichat.dev.upstreamUI', '1');
    render(<AntiChatGate upstream={Upstream} />);
    await waitFor(() => expect(screen.getByText('upstream app')).toBeTruthy());
    expect(screen.queryByText('antichat shell')).toBeNull();
  });
});
