import React from 'react';
import {Text} from 'react-native';
import {act, render, screen} from '@testing-library/react-native';

import {fakePortNames, getPorts, setPorts, usePort} from '..';
import {createFakePorts} from '../../contracts/fakes';

describe('adapters', () => {
  afterEach(() => setPorts());

  it('serves every port, fakes where nothing real is registered', () => {
    const ports = getPorts();
    expect(Object.keys(ports).sort()).toEqual([
      'chat',
      'connectivity',
      'conversations',
      'files',
      'memory',
      'model',
      'tools',
      'voice',
    ]);
    expect(getPorts()).toBe(ports);
    // Under Jest the fake backend is selected: every port is a fake.
    expect(fakePortNames()).toHaveLength(8);
  });

  it('re-renders on a port change and follows a changed selector', async () => {
    const ports = createFakePorts();
    setPorts(ports);
    const [first, second] = ports.conversations.conversations;

    function Title({id}: {id: string}) {
      const title = usePort(ports.conversations, c => c.get(id)?.title);
      return <Text>{title}</Text>;
    }
    render(<Title id={first.id} />);
    expect(screen.getByText(first.title)).toBeTruthy();

    await act(async () => {
      await ports.conversations.rename(first.id, 'Renamed');
    });
    expect(screen.getByText('Renamed')).toBeTruthy();

    // The selector closes over props: a new id must not return a stale value.
    screen.rerender(<Title id={second.id} />);
    expect(screen.getByText(second.title)).toBeTruthy();
  });
});
