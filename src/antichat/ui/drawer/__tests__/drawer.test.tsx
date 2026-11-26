import '../../../testing/setup';

import React from 'react';
import {act, fireEvent, render, screen} from '@testing-library/react-native';
import {GestureHandlerRootView} from 'react-native-gesture-handler';

import {setPorts} from '../../../adapters';
import {shellSession} from '../../../app/session';
import {createFakePorts, type FakePorts} from '../../../contracts/fakes';
import {ToastHost, toast} from '../../primitives';
import {setDeviceUnlock} from '../../chatmenu/deviceUnlock';
import {lockState} from '../../chatmenu/lockState';
import {DrawerContent} from '../DrawerContent';
import {UNDO_MS, flushPendingDeletes} from '../historyActions';
import {historyUi} from '../historyUi';
import {registerDrawerShortcut} from '../shortcuts';

jest.mock('@legendapp/list/react-native', () => {
  const React = require('react');
  const {FlatList} = require('react-native');
  return {
    LegendList: React.forwardRef((props: any, ref: any) =>
      React.createElement(FlatList, {
        ...props,
        ref,
        initialNumToRender: 100,
        onScrollToIndexFailed: () => {},
      }),
    ),
  };
});

jest.mock('@react-navigation/drawer', () => ({
  useDrawerStatus: () => 'open',
}));

const navigation = {
  navigate: jest.fn(),
  closeDrawer: jest.fn(),
} as any;

function menuOf(rowId: string) {
  // The row sits inside the (mocked) native menu view.
  let node = screen.getByTestId(rowId).parent;
  while (node && !node.props.actions) {
    node = node.parent;
  }
  return node!;
}

describe('drawer', () => {
  let ports: FakePorts;

  beforeEach(() => {
    jest.useFakeTimers();
    jest.clearAllMocks();
    ports = createFakePorts();
    setPorts(ports);
    shellSession.newChat();
    historyUi.startRowRename(null);
    lockState.lockAll();
    toast.hide();
  });
  afterEach(() => {
    flushPendingDeletes();
    setDeviceUnlock();
    setPorts();
    jest.useRealTimers();
  });

  const show = () =>
    render(
      <GestureHandlerRootView>
        <DrawerContent
          navigation={navigation}
          state={{} as any}
          descriptors={{}}
        />
        <ToastHost />
      </GestureHandlerRootView>,
    );
  const first = () => ports.conversations.conversations[2];
  const row = (id: string) => `chat-row-${id}`;

  it('lists pinned chats, date groups, the new-chat row and the profile row', () => {
    show();
    expect(screen.getByText('Pinned')).toBeTruthy();
    expect(screen.getByText('Today')).toBeTruthy();
    expect(screen.getByText('Weekend trip to Lisbon')).toBeTruthy();
    expect(screen.getByTestId('drawer-new-chat-row')).toBeTruthy();
    expect(screen.getByTestId('drawer-settings')).toBeTruthy();
    // No shortcut exists yet, so none is shown.
    expect(screen.queryByTestId(/^drawer-shortcut-/)).toBeNull();
  });

  it('keeps registered shortcuts hidden in the first version', () => {
    show();
    const onPress = jest.fn();
    let remove = () => {};
    act(() => {
      remove = registerDrawerShortcut({
        id: 'images',
        order: 10,
        title: () => 'Images',
        icon: 'image',
        onPress,
      });
    });
    // The first version shows no shortcuts (app/scope.ts): registered, hidden.
    expect(screen.queryByTestId('drawer-shortcut-images')).toBeNull();
    expect(onPress).not.toHaveBeenCalled();
    act(() => remove());
    expect(screen.queryByTestId('drawer-shortcut-images')).toBeNull();
  });

  it('says so when there are no chats', () => {
    ports = createFakePorts({conversations: {empty: true}});
    setPorts(ports);
    show();
    expect(screen.getByTestId('drawer-empty')).toBeTruthy();
  });

  it('opens a chat and closes the drawer', async () => {
    show();
    await act(async () => {
      fireEvent.press(screen.getByTestId(row(first().id)));
    });
    expect(shellSession.activeConversationId).toBe(first().id);
    expect(navigation.closeDrawer).toHaveBeenCalled();
  });

  it('renames a chat in its own row', async () => {
    show();
    const chat = first();
    act(() => {
      menuOf(row(chat.id)).props.onPressAction({
        nativeEvent: {event: 'rename'},
      });
    });
    const field = screen.getByTestId(`${row(chat.id)}-rename`);
    expect(field.props.value).toBe(chat.title);
    fireEvent.changeText(field, '  Better name ');
    await act(async () => {
      fireEvent(field, 'submitEditing');
    });
    expect(ports.conversations.get(chat.id)?.title).toBe('Better name');
    expect(screen.queryByTestId(`${row(chat.id)}-rename`)).toBeNull();
    expect(screen.getByText('Better name')).toBeTruthy();
  });

  it('pins from the menu and archives with an undo', async () => {
    show();
    const chat = first();
    await act(async () => {
      menuOf(row(chat.id)).props.onPressAction({nativeEvent: {event: 'pin'}});
    });
    expect(ports.conversations.get(chat.id)?.pinned).toBe(true);

    await act(async () => {
      menuOf(row(chat.id)).props.onPressAction({
        nativeEvent: {event: 'archive'},
      });
    });
    expect(ports.conversations.get(chat.id)?.archived).toBe(true);
    expect(screen.queryByTestId(row(chat.id))).toBeNull();

    await act(async () => {
      fireEvent.press(screen.getByTestId('toast-action'));
      await Promise.resolve();
      await Promise.resolve();
    });
    expect(ports.conversations.get(chat.id)?.archived).toBe(false);
    // It was pinned before it was archived, and is again.
    expect(ports.conversations.get(chat.id)?.pinned).toBe(true);
  });

  it('deletes without asking, and takes it back on Undo', async () => {
    show();
    const chat = first();
    shellSession.open(chat.id);
    act(() => {
      fireEvent.press(screen.getByTestId(`${row(chat.id)}-swipe-delete`));
    });
    // Gone from the list and closed, but not deleted yet.
    expect(screen.queryByTestId(row(chat.id))).toBeNull();
    expect(shellSession.activeConversationId).toBeNull();
    expect(ports.conversations.get(chat.id)).toBeTruthy();

    act(() => {
      fireEvent.press(screen.getByTestId('toast-action'));
    });
    expect(screen.getByTestId(row(chat.id))).toBeTruthy();
    expect(shellSession.activeConversationId).toBe(chat.id);
    act(() => jest.advanceTimersByTime(UNDO_MS + 100));
    expect(ports.conversations.get(chat.id)).toBeTruthy();
  });

  it('really deletes once the undo time has passed', async () => {
    show();
    const chat = first();
    act(() => {
      menuOf(row(chat.id)).props.onPressAction({
        nativeEvent: {event: 'delete'},
      });
    });
    expect(ports.conversations.get(chat.id)).toBeTruthy();
    await act(async () => {
      jest.advanceTimersByTime(UNDO_MS + 100);
    });
    expect(ports.conversations.get(chat.id)).toBeUndefined();
  });

  it('makes an earlier delete final when another one starts', async () => {
    show();
    const [a, b] = [first(), ports.conversations.conversations[3]];
    await act(async () => {
      menuOf(row(a.id)).props.onPressAction({nativeEvent: {event: 'delete'}});
      menuOf(row(b.id)).props.onPressAction({nativeEvent: {event: 'delete'}});
    });
    expect(ports.conversations.get(a.id)).toBeUndefined();
    expect(ports.conversations.get(b.id)).toBeTruthy();
  });

  it('hides a locked chat’s title and opens it only after unlock', async () => {
    const chat = first();
    await ports.conversations.setLocked(chat.id, true);
    let answer: 'ok' | 'cancelled' = 'cancelled';
    setDeviceUnlock({
      available: async () => true,
      authenticate: async () => answer,
    });
    show();
    expect(screen.queryByText(chat.title)).toBeNull();
    expect(screen.getByText('Locked chat')).toBeTruthy();
    // No rename or share for a chat that cannot be read.
    expect(
      menuOf(row(chat.id)).props.actions.map((a: {id: string}) => a.id),
    ).toEqual(['pin', 'archive', 'delete']);

    await act(async () => {
      fireEvent.press(screen.getByTestId(row(chat.id)));
    });
    expect(shellSession.activeConversationId).toBeNull();

    answer = 'ok';
    await act(async () => {
      fireEvent.press(screen.getByTestId(row(chat.id)));
    });
    expect(shellSession.activeConversationId).toBe(chat.id);
    expect(screen.getByText(chat.title)).toBeTruthy();
  });

  it('turns into search while the field is in use', async () => {
    show();
    fireEvent(screen.getByTestId('drawer-search'), 'focus');
    expect(screen.getByTestId('drawer-search-cancel')).toBeTruthy();
    expect(screen.queryByTestId('drawer-settings')).toBeNull();
    fireEvent.changeText(screen.getByTestId('drawer-search'), 'lisbon');
    await act(async () => {
      jest.advanceTimersByTime(200);
      await Promise.resolve();
      await Promise.resolve();
    });
    const hit = ports.conversations.conversations.find(c =>
      c.title.includes('Lisbon'),
    )!;
    await act(async () => {
      fireEvent.press(screen.getByTestId(`search-hit-${hit.id}`));
    });
    expect(shellSession.activeConversationId).toBe(hit.id);
    expect(shellSession.focus?.query).toBe('lisbon');

    fireEvent.press(screen.getByTestId('drawer-search-cancel'));
    expect(screen.getByTestId('drawer-settings')).toBeTruthy();
  });

  it('starts a new chat from the row and from the button', () => {
    show();
    shellSession.open(first().id);
    fireEvent.press(screen.getByTestId('drawer-new-chat-row'));
    expect(shellSession.activeConversationId).toBeNull();
    shellSession.open(first().id);
    fireEvent.press(screen.getByTestId('drawer-new-chat'));
    expect(shellSession.activeConversationId).toBeNull();
  });
});
