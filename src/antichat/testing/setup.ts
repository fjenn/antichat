/**
 * Jest setup for AntiChat suites. Import it first in a test file:
 *
 *   import '../../testing/setup';
 *
 * It mocks the native UI libraries our primitives sit on and registers the
 * themes, so a primitive renders in Jest exactly as it is written. Kept here,
 * not in the shared jest config, so upstream's suites are untouched.
 */
/* eslint-env jest */
jest.mock('react-native-unistyles', () => {
  const themes: Record<string, unknown> = {};
  const insets = {top: 0, bottom: 0, left: 0, right: 0, ime: 0};
  const rt = {
    insets,
    fontScale: 1,
    rtl: false,
    themeName: 'light',
    hasAdaptiveThemes: true,
    screen: {width: 390, height: 844},
  };
  const theme = () => themes[rt.themeName] ?? Object.values(themes)[0];
  const fill = {position: 'absolute', left: 0, right: 0, top: 0, bottom: 0};
  return {
    StyleSheet: {
      hairlineWidth: 0.5,
      absoluteFill: fill,
      absoluteFillObject: fill,
      configure: (config: {themes: Record<string, unknown>}) =>
        Object.assign(themes, config.themes),
      create: (sheet: unknown) =>
        typeof sheet === 'function' ? sheet(theme(), rt) : sheet,
    },
    useUnistyles: () => ({theme: theme(), rt}),
    UnistylesRuntime: {
      ...rt,
      setTheme: jest.fn(),
      setAdaptiveThemes: jest.fn(),
      updateTheme: jest.fn(),
      getTheme: theme,
    },
  };
});

// Upstream's mapped mock resolves to itself; a small in-memory store instead.
jest.mock('@react-native-async-storage/async-storage', () => {
  const store = new Map<string, string>();
  return {
    __esModule: true,
    default: {
      getItem: async (key: string) => store.get(key) ?? null,
      setItem: async (key: string, value: string) => {
        store.set(key, value);
      },
      removeItem: async (key: string) => {
        store.delete(key);
      },
      clear: async () => store.clear(),
    },
  };
});

jest.mock('react-native-pulsar', () => {
  const effect = () => jest.fn();
  return {
    Presets: {
      System: {
        impactLight: effect(),
        impactMedium: effect(),
        impactSoft: effect(),
        selection: effect(),
        notificationSuccess: effect(),
        notificationWarning: effect(),
        notificationError: effect(),
      },
    },
    Settings: {enableHaptics: jest.fn()},
  };
});

jest.mock('@callstack/liquid-glass', () => {
  const {View} = require('react-native');
  return {LiquidGlassView: View, isLiquidGlassSupported: false};
});

jest.mock('@sbaiahmed1/react-native-blur', () => {
  const {View} = require('react-native');
  return {BlurView: View};
});

jest.mock('react-native-linear-gradient', () => {
  const {View} = require('react-native');
  return View;
});

jest.mock('@react-native-menu/menu', () => {
  const React = require('react');
  const {View} = require('react-native');
  return {
    MenuView: ({children, actions, onPressAction, testID}: any) =>
      React.createElement(
        View,
        {testID, actions, onPressAction, accessibilityRole: 'none'},
        children,
      ),
  };
});

jest.mock('@lodev09/react-native-true-sheet', () => {
  const React = require('react');
  const {View} = require('react-native');
  const TrueSheet = React.forwardRef(({children}: any, ref: any) => {
    const [open, setOpen] = React.useState(false);
    React.useImperativeHandle(ref, () => ({
      present: async () => setOpen(true),
      dismiss: async () => setOpen(false),
    }));
    return open ? React.createElement(View, null, children) : null;
  });
  return {TrueSheet};
});

jest.mock('react-native-svg', () => {
  const React = require('react');
  const {View} = require('react-native');
  const Stub = (props: any) => React.createElement(View, props);
  return {__esModule: true, default: Stub, Svg: Stub, Path: Stub};
});

jest.mock('../ui/primitives/icons', () => {
  const React = require('react');
  const {View} = require('react-native');
  const Glyph = () => React.createElement(View, null);
  return {
    glyphs: new Proxy({}, {get: () => Glyph}),
    DIRECTIONAL: new Set(['chevronForward', 'chevronBack']),
    SF_SYMBOLS: {},
  };
});

// Registers the light and dark themes with the Unistyles mock.
require('../theme/unistyles');
