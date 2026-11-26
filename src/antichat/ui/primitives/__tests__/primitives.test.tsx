import '../../../testing/setup';

import React, {createRef} from 'react';
import {act, fireEvent, render, screen} from '@testing-library/react-native';
import {Presets} from 'react-native-pulsar';

import {
  Button,
  Chip,
  ContextMenu,
  GlassSurface,
  IconButton,
  InlineError,
  ListRow,
  Sheet,
  Skeleton,
  Text,
  TextField,
  ToastHost,
  Toggle,
  haptics,
  setHapticsEnabled,
  toast,
  type SheetHandle,
} from '..';
import {typography} from '../../../theme';

const tap = Presets.System.impactLight as jest.Mock;

beforeEach(() => {
  jest.clearAllMocks();
  setHapticsEnabled(true);
});

describe('Text', () => {
  it('caps font scaling per variant so chrome cannot outgrow its bar', () => {
    render(
      <>
        <Text>body</Text>
        <Text variant="button">button</Text>
      </>,
    );
    expect(screen.getByText('body').props.maxFontSizeMultiplier).toBe(
      typography.body.maxFontSizeMultiplier,
    );
    expect(screen.getByText('button').props.maxFontSizeMultiplier).toBe(1.6);
    expect(screen.getByText('body').props.allowFontScaling).not.toBe(false);
  });
});

describe('Button', () => {
  it('is a labelled button that presses with a light tap', () => {
    const onPress = jest.fn();
    render(<Button label="Continue" onPress={onPress} />);
    const button = screen.getByRole('button', {name: 'Continue'});
    fireEvent.press(button);
    expect(onPress).toHaveBeenCalledTimes(1);
    expect(tap).toHaveBeenCalledTimes(1);
  });

  it('reports busy and disabled to screen readers and ignores presses', () => {
    const onPress = jest.fn();
    render(<Button label="Saving" loading onPress={onPress} />);
    const button = screen.getByRole('button', {name: 'Saving'});
    expect(button).toBeDisabled();
    expect(button).toBeBusy();
    fireEvent.press(button);
    expect(onPress).not.toHaveBeenCalled();
  });

  it('grows with large text instead of clipping it', () => {
    render(<Button label="Continue" testID="b" />);
    const flat = JSON.stringify(screen.toJSON());
    expect(flat).toContain('"minHeight":44');
    expect(flat).not.toMatch(/"height":44\b/);
  });
});

describe('IconButton', () => {
  it.each(['plain', 'filled', 'accent', 'glass'] as const)(
    '%s has a label and a 44-point target',
    variant => {
      const onPress = jest.fn();
      render(
        <IconButton
          icon="newChat"
          variant={variant}
          size={36}
          accessibilityLabel="New chat"
          onPress={onPress}
        />,
      );
      const button = screen.getByRole('button', {name: 'New chat'});
      expect(button.props.hitSlop).toBe(4);
      fireEvent.press(button);
      expect(onPress).toHaveBeenCalledTimes(1);
    },
  );
});

describe('Chip', () => {
  it('announces selection and offers a labelled remove button', () => {
    const onRemove = jest.fn();
    render(
      <Chip label="Search" selected onPress={jest.fn()} onRemove={onRemove} />,
    );
    expect(screen.getByRole('button', {name: 'Search'})).toBeSelected();
    fireEvent.press(screen.getByRole('button', {name: 'Remove Search'}));
    expect(onRemove).toHaveBeenCalled();
  });
});

describe('Toggle', () => {
  it('is a switch that reports its state and flips with a selection tick', () => {
    const onValueChange = jest.fn();
    render(
      <Toggle
        value={false}
        onValueChange={onValueChange}
        accessibilityLabel="Haptic feedback"
      />,
    );
    const toggle = screen.getByRole('switch', {name: 'Haptic feedback'});
    expect(toggle).not.toBeChecked();
    fireEvent.press(toggle);
    expect(onValueChange).toHaveBeenCalledWith(true);
    expect(Presets.System.selection).toHaveBeenCalled();
  });
});

describe('ListRow', () => {
  it('reads title, subtitle and value as one button', () => {
    const onPress = jest.fn();
    render(
      <ListRow
        title="Storage"
        subtitle="Runs on this phone"
        value="2.1 GB"
        chevron
        onPress={onPress}
      />,
    );
    fireEvent.press(
      screen.getByRole('button', {name: 'Storage, Runs on this phone, 2.1 GB'}),
    );
    expect(onPress).toHaveBeenCalled();
  });

  it('is not a button when it only hosts a control', () => {
    render(
      <ListRow
        title="Haptic feedback"
        trailing={
          <Toggle
            value
            onValueChange={jest.fn()}
            accessibilityLabel="Haptic feedback"
          />
        }
      />,
    );
    expect(screen.queryByRole('button')).toBeNull();
    expect(screen.getByRole('switch')).toBeChecked();
  });
});

describe('TextField', () => {
  it('labels the input, shows the error and clears', () => {
    const onChangeText = jest.fn();
    render(
      <TextField
        label="Name"
        value="Ada"
        onChangeText={onChangeText}
        clearable
        error="Use 40 characters or fewer."
      />,
    );
    expect(screen.getByLabelText('Name').props.value).toBe('Ada');
    expect(screen.getByText('Use 40 characters or fewer.')).toBeTruthy();
    fireEvent.press(screen.getByRole('button', {name: 'Clear text'}));
    expect(onChangeText).toHaveBeenCalledWith('');
  });
});

describe('InlineError', () => {
  it('is an alert with a retry action', () => {
    const onRetry = jest.fn();
    render(
      <InlineError message="The answer stopped early." onRetry={onRetry} />,
    );
    expect(screen.getByRole('alert')).toBeTruthy();
    fireEvent.press(screen.getByRole('button', {name: 'Try again'}));
    expect(onRetry).toHaveBeenCalled();
  });
});

describe('toast', () => {
  beforeEach(() => jest.useFakeTimers());
  afterEach(() => jest.useRealTimers());

  it('shows one message at a time and goes away by itself', () => {
    render(<ToastHost />);
    act(() => toast.show({message: 'Copied'}));
    act(() => toast.show({message: 'Chat pinned', kind: 'success'}));
    expect(screen.queryByText('Copied')).toBeNull();
    expect(screen.getByText('Chat pinned')).toBeTruthy();
    expect(Presets.System.notificationSuccess).toHaveBeenCalledTimes(1);
    act(() => jest.advanceTimersByTime(3000));
    expect(screen.queryByText('Chat pinned')).toBeNull();
  });
});

describe('Sheet', () => {
  it('presents and dismisses through its handle', async () => {
    const ref = createRef<SheetHandle>();
    render(
      <Sheet ref={ref} title="Sheet">
        <Text>Body</Text>
      </Sheet>,
    );
    expect(screen.queryByText('Body')).toBeNull();
    await act(async () => ref.current?.present());
    expect(screen.getByRole('header', {name: 'Sheet'})).toBeTruthy();
    await act(async () => ref.current?.dismiss());
    expect(screen.queryByText('Body')).toBeNull();
  });
});

describe('ContextMenu', () => {
  it('maps items to native actions and reports the choice', () => {
    const onSelect = jest.fn();
    render(
      <ContextMenu
        testID="menu"
        onSelect={onSelect}
        items={[
          {id: 'pin', title: 'Pin', checked: true},
          {id: 'delete', title: 'Delete', destructive: true},
        ]}>
        <Text>Row</Text>
      </ContextMenu>,
    );
    const menu = screen.getByTestId('menu');
    expect(menu.props.actions).toEqual([
      expect.objectContaining({id: 'pin', title: 'Pin', state: 'on'}),
      expect.objectContaining({
        id: 'delete',
        attributes: expect.objectContaining({destructive: true}),
      }),
    ]);
    act(() => menu.props.onPressAction({nativeEvent: {event: 'delete'}}));
    expect(onSelect).toHaveBeenCalledWith('delete');
  });
});

describe('surfaces', () => {
  it('falls back to a solid, bordered surface without Liquid Glass', () => {
    render(
      <GlassSurface testID="glass">
        <Text>Inside</Text>
      </GlassSurface>,
    );
    const style = JSON.stringify(screen.getByTestId('glass').props.style);
    expect(style).toContain('borderColor');
    expect(screen.getByText('Inside')).toBeTruthy();
  });

  it('hides skeletons from screen readers', () => {
    render(<Skeleton />);
    const json = JSON.stringify(screen.toJSON());
    expect(json).toContain('"importantForAccessibility":"no-hide-descendants"');
  });
});

describe('haptics', () => {
  it('does nothing when switched off', () => {
    setHapticsEnabled(false);
    haptics.tap();
    haptics.success();
    expect(tap).not.toHaveBeenCalled();
    expect(haptics.streamTick(10_000)).toBe(false);
    expect(Presets.System.impactSoft).not.toHaveBeenCalled();
  });

  it('limits the streaming tick to a steady rate', () => {
    const soft = Presets.System.impactSoft as jest.Mock;
    expect(haptics.streamTick(100_000)).toBe(true);
    expect(haptics.streamTick(100_030)).toBe(false);
    expect(haptics.streamTick(100_079)).toBe(false);
    expect(haptics.streamTick(100_080)).toBe(true);
    expect(soft).toHaveBeenCalledTimes(2);
  });

  it('survives a phone without a haptic engine', () => {
    tap.mockImplementationOnce(() => {
      throw new Error('no engine');
    });
    expect(() => haptics.tap()).not.toThrow();
  });
});
