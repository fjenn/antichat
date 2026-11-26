import '../../../testing/setup';

import React from 'react';
import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
} from '@testing-library/react-native';

import {
  RELAY,
  makeStore,
  type Route,
} from '../../../engine/mcp/__tests__/support';
import {ApprovalCard, argumentRows} from '../ApprovalCard';
import {ConnectAppCard} from '../ConnectAppCard';
import {ConnectorsSheets} from '../ConnectorsHost';
import {ConnectorsView} from '../ConnectorsScreen';

jest.mock('../AppLogo', () => ({AppLogo: () => null}));
jest.mock('../session', () => ({useConnectors: jest.fn()}));
jest.mock('../../../app/screens/ScreenHeader', () => ({
  ScreenHeader: () => null,
}));

const routes = (state: {connected: boolean}): Route[] => [
  request =>
    request.url === `${RELAY}/v1/toolkits`
      ? {
          json: {
            toolkits: [
              {
                slug: 'gmail',
                name: 'Gmail',
                description: 'Mail',
                auth: 'oauth',
              },
              {slug: 'zoom', name: 'Zoom', description: 'Calls', auth: 'oauth'},
            ],
          },
        }
      : null,
  request =>
    request.url === `${RELAY}/v1/connections` && request.method === 'GET'
      ? {
          json: {
            connections: state.connected
              ? [{id: 'c1', toolkit: 'gmail', status: 'active'}]
              : [],
          },
        }
      : null,
  request =>
    request.url === `${RELAY}/v1/session` ? {json: {ok: true}} : null,
  request => {
    if (request.url !== `${RELAY}/v1/connections/link`) {
      return null;
    }
    state.connected = true;
    return {json: {url: 'https://connect.test/l', id: 'l'}};
  },
  request => {
    if (request.url !== `${RELAY}/v1/connections/c1`) {
      return null;
    }
    state.connected = false;
    return {json: {ok: true}};
  },
];

describe('Connectors screen', () => {
  it('lists apps, filters them, connects and disconnects one', async () => {
    const state = {connected: false};
    const {store, opened} = makeStore(routes(state));
    render(<ConnectorsView store={store} />);
    await waitFor(() =>
      expect(screen.getByTestId('popular-gmail')).toBeTruthy(),
    );
    // Categories start collapsed, with their app count; a tap opens one.
    expect(screen.queryByTestId('app-gmail')).toBeNull();
    const header = screen.getByTestId('group-header-other');
    expect(header.props.accessibilityState.expanded).toBe(false);
    fireEvent.press(header);
    expect(screen.getByTestId('app-gmail')).toBeTruthy();
    expect(screen.getByTestId('app-zoom')).toBeTruthy();
    // Adding a custom server is right under the search field.
    expect(screen.getByTestId('add-server')).toBeTruthy();

    fireEvent.changeText(screen.getByTestId('connectors-search'), 'zo');
    expect(screen.getByTestId('app-zoom')).toBeTruthy();
    expect(screen.queryByTestId('app-gmail')).toBeNull();
    expect(screen.queryByTestId('add-server')).toBeNull();
    fireEvent.changeText(screen.getByTestId('connectors-search'), 'nothing');
    expect(screen.getByTestId('connectors-empty')).toBeTruthy();
    fireEvent.changeText(screen.getByTestId('connectors-search'), '');

    fireEvent.press(screen.getByTestId('app-gmail'));
    await waitFor(() => expect(screen.getByTestId('app-detail')).toBeTruthy());
    await act(async () => {
      fireEvent.press(screen.getByTestId('connect-card-connect'));
    });
    await waitFor(() => expect(store.connectedSlugs).toEqual(['gmail']));
    expect(opened).toEqual(['https://connect.test/l']);
    await waitFor(() =>
      expect(screen.getByTestId('connected-gmail')).toBeTruthy(),
    );

    await act(async () => {
      fireEvent.press(screen.getByTestId('app-disconnect'));
    });
    await waitFor(() => expect(store.connectedSlugs).toEqual([]));
    expect(screen.queryByTestId('connected-gmail')).toBeNull();
  });

  it('greys everything while offline', async () => {
    let online = true;
    const {store, doFetch} = makeStore(routes({connected: false}), {
      isOnline: () => online,
    });
    await store.refresh();
    online = false;
    const calls = doFetch.calls.length;
    render(<ConnectorsView store={store} />);
    await waitFor(() =>
      expect(screen.getByTestId('group-header-other')).toBeTruthy(),
    );
    expect(screen.getByTestId('connectors-offline')).toBeTruthy();
    fireEvent.press(screen.getByTestId('group-header-other'));
    expect(
      screen.getByTestId('app-gmail').props.accessibilityState.disabled,
    ).toBe(true);
    expect(
      screen.getByTestId('add-server').props.accessibilityState.disabled,
    ).toBe(true);
    fireEvent.press(screen.getByTestId('app-gmail'));
    expect(screen.queryByTestId('app-detail')).toBeNull();
    expect(doFetch.calls.length).toBe(calls);
  });
});

describe('Connect card', () => {
  it('offers the connectors screen for an unknown app and is disabled offline', async () => {
    const {store} = makeStore(routes({connected: false}), {
      isOnline: () => false,
    });
    const open = jest.fn();
    const {rerender} = render(
      <ConnectAppCard
        store={store}
        slug={null}
        name="Frobnicator"
        onOpenConnectors={open}
      />,
    );
    fireEvent.press(screen.getByTestId('connect-card-open'));
    expect(open).toHaveBeenCalled();
    rerender(<ConnectAppCard store={store} slug="gmail" name="Gmail" />);
    expect(
      screen.getByTestId('connect-card-connect').props.accessibilityState
        .disabled,
    ).toBe(true);
    expect(screen.getByText('Needs a connection')).toBeTruthy();
  });
});

describe('Approval', () => {
  it('shows what will be sent', () => {
    expect(
      argumentRows({
        recipient_email: 'a@b.c',
        body: 'x'.repeat(300),
        n: 2,
        e: '',
      }),
    ).toEqual([
      {name: 'recipient email', value: 'a@b.c'},
      {name: 'body', value: `${'x'.repeat(240)}…`},
      {name: 'n', value: '2'},
    ]);
    const onAnswer = jest.fn();
    render(
      <ApprovalCard
        request={{
          id: '1',
          key: 'k',
          app: 'Gmail',
          action: 'Send email',
          arguments: {subject: 'Hi'},
          createdAt: 0,
        }}
        onAnswer={onAnswer}
      />,
    );
    expect(screen.getByText('Gmail: Send email')).toBeTruthy();
    expect(screen.getByText('Hi')).toBeTruthy();
    fireEvent.press(screen.getByTestId('approval-always'));
    expect(onAnswer).toHaveBeenCalledWith('always');
  });

  it('the host presents a pending write and passes the answer on', async () => {
    const {store} = makeStore([]);
    render(<ConnectorsSheets store={store} />);
    let allowed: boolean | undefined;
    await act(async () => {
      store.permissions
        .allow({
          key: 'k',
          app: 'Gmail',
          action: 'Send email',
          arguments: {},
          write: true,
        })
        .then(value => {
          allowed = value;
        });
    });
    await waitFor(() =>
      expect(screen.getByTestId('approval-card')).toBeTruthy(),
    );
    await act(async () => {
      fireEvent.press(screen.getByTestId('approval-deny'));
    });
    await waitFor(() => expect(allowed).toBe(false));
    expect(screen.queryByTestId('approval-card')).toBeNull();

    await act(async () => {
      store.showCard('Gmail');
    });
    await waitFor(() =>
      expect(screen.getByTestId('connect-card')).toBeTruthy(),
    );
  });
});
