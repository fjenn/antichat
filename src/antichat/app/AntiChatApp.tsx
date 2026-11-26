import '../theme/unistyles';

import React, {useEffect, useMemo} from 'react';
import {Linking, LogBox, StatusBar, useWindowDimensions} from 'react-native';
import {
  DefaultTheme,
  NavigationContainer,
  createNavigationContainerRef,
  getFocusedRouteNameFromRoute,
  type Theme as NavigationTheme,
} from '@react-navigation/native';
import {
  createDrawerNavigator,
  type DrawerContentComponentProps,
} from '@react-navigation/drawer';
import {createStackNavigator} from '@react-navigation/stack';
import {GestureHandlerRootView} from 'react-native-gesture-handler';
import {KeyboardProvider} from 'react-native-keyboard-controller';
import {SafeAreaProvider} from 'react-native-safe-area-context';
import {StyleSheet, useUnistyles} from 'react-native-unistyles';

import {currentBackend, fakeOptions, setBackend} from '../adapters/backend';
import {isAutoSource, requestAuto} from '../ui/chat/debug';
// ANTICHAT M4: the drawer contents, archive list and overlays.
import {HistoryOverlays} from '../ui/chatmenu';
import {ArchivedChatsScreen, DrawerContent} from '../ui/drawer';
import {FirstRunGate} from '../ui/onboarding';
import {ConnectorsHost, ConnectorsScreen} from '../ui/connectors';
import {ToastHost} from '../ui/primitives';
import {memoryScreens} from '../ui/memory';
import {settingsScreens} from '../ui/settings';
import {setAppNavigate} from './navigate';
import {switchOffUpstreamBaggage} from './baggage';
import {parseDeepLink} from './deeplinks';
import {devToolsEnabled, registerDevMenu} from './flags';
import type {DrawerParams, MainStackParams} from './routes';
import {ChatShellScreen} from './screens/ChatShellScreen';
import {GalleryScreen} from './screens/GalleryScreen';
import {shellSession} from './session';

// The warning toast sits on top of the composer; warnings stay in the debugger.
LogBox.ignoreAllLogs(true);

// The warning toast sits on top of the composer; warnings stay in the debugger.
LogBox.ignoreAllLogs(true);

const Drawer = createDrawerNavigator<DrawerParams>();
const Stack = createStackNavigator<MainStackParams>();
const navigationRef = createNavigationContainerRef<DrawerParams>();

/** Share of the screen the drawer covers, and its cap on large phones. */
const DRAWER_WIDTH_RATIO = 0.84;
const DRAWER_MAX_WIDTH = 360;
interface LegacyPan {
  activeOffsetX(offsets: [number, number]): LegacyPan;
}

/** Points a leftward swipe travels before the drawer follows it. */
const DRAWER_CLOSE_SWIPE_OFFSET = 28;

function MainStack() {
  const {theme} = useUnistyles();
  return (
    <Stack.Navigator
      screenOptions={{
        headerShown: false,
        cardStyle: {backgroundColor: theme.colors.background},
      }}>
      <Stack.Screen name="Chat" component={ChatShellScreen} />
      <Stack.Screen name="Gallery" component={GalleryScreen} />
      <Stack.Screen name="ArchivedChats" component={ArchivedChatsScreen} />
      {devToolsEnabled() ? (
        <Stack.Screen name="HistoryLab" getComponent={historyLab} />
      ) : null}
      {/* M6: Settings, Models, Storage and their sub-screens. */}
      {settingsScreens(Stack.Screen)}
      {/* M9: manage memories. Projects are not in the first version. */}
      {memoryScreens(Stack)}
      <Stack.Screen name="Connectors" component={ConnectorsScreen} />
    </Stack.Navigator>
  );
}

function historyLab() {
  return require('../ui/drawer/dev/HistoryLabScreen').HistoryLabScreen;
}

function renderDrawer(props: DrawerContentComponentProps) {
  return <DrawerContent {...props} />;
}

function openDeepLink(url: string | null | undefined): void {
  const link = url ? parseDeepLink(url) : null;
  if (!link || !navigationRef.isReady()) {
    return;
  }
  if (link.route === 'dev') {
    // Debug builds: UI tests pick the in-memory backend and its speed.
    // Asking for what is already running must not reload the app.
    const now = fakeOptions();
    const sameSpeed =
      !link.fake ||
      (link.fake.tokensPerSecond === now.tokensPerSecond &&
        link.fake.firstTokenMs === now.firstTokenMs);
    if (!sameSpeed || link.backend !== currentBackend()) {
      setBackend(link.backend, link.fake).catch(() => {});
    }
    return;
  }
  if (link.route === 'auto') {
    if (isAutoSource(link.source)) {
      requestAuto(link.source);
    }
    return;
  }
  if (link.route === 'settings') {
    navigationRef.navigate('Main', {screen: 'Settings'});
    return;
  }
  if (link.conversationId) {
    shellSession.open(link.conversationId);
  } else {
    shellSession.newChat();
  }
  navigationRef.navigate('Main', {screen: 'Chat'});
}

/** Loaded lazily: with the fakes, upstream's chat engine is never touched. */
function RealBackendHost() {
  const {ChatSessionHost} = require('../adapters/chat');
  return <ChatSessionHost />;
}

/** The AntiChat root: providers, the drawer, the stack inside it. */
export function AntiChatApp() {
  const {theme} = useUnistyles();
  const {width} = useWindowDimensions();

  useEffect(() => {
    switchOffUpstreamBaggage();
    // M4: temporary-chat bookkeeping follows what the shell shows.
    require('../ui/chatmenu').installShellBridge();
    registerDevMenu();
    // The whole engine (prompt, tools, memory, files, models) behind one
    // call; only this root makes it, so upstream's UI stays stock.
    if (currentBackend() === 'real') {
      (require('../engine/install') as typeof import('../engine/install'))
        .installEngine()
        // M9: the memory screens read the engine that was just installed.
        .then(engine => {
          if (engine.memory) {
            require('../ui/memory').registerMemoryUi({engine: engine.memory});
          }
        })
        .catch(() => undefined);
      require('../adapters/turnExtras').startTurnExtras();
      setAppNavigate(route => {
        if (navigationRef.isReady()) {
          (navigationRef as any).navigate('Main', {screen: route});
        }
      });
    }
    const subscription = Linking.addEventListener('url', event =>
      openDeepLink(event.url),
    );
    return () => subscription.remove();
  }, []);

  const navigationTheme = useMemo<NavigationTheme>(
    () => ({
      ...DefaultTheme,
      dark: theme.dark,
      colors: {
        ...DefaultTheme.colors,
        primary: theme.colors.accent,
        background: theme.colors.background,
        card: theme.colors.background,
        text: theme.colors.textPrimary,
        border: theme.colors.border,
        notification: theme.colors.danger,
      },
    }),
    [theme],
  );

  return (
    <GestureHandlerRootView style={styles.root}>
      <StatusBar barStyle={theme.dark ? 'light-content' : 'dark-content'} />
      <SafeAreaProvider>
        <KeyboardProvider statusBarTranslucent navigationBarTranslucent>
          {/* M6: the welcome screen of a new install sits over the app. */}
          <FirstRunGate
            onOpenStore={() => {
              if (navigationRef.isReady()) {
                (navigationRef as any).navigate('Main', {screen: 'Models'});
              }
            }}>
            <NavigationContainer
              ref={navigationRef}
              theme={navigationTheme}
              onReady={() => {
                Linking.getInitialURL()
                  .then(openDeepLink)
                  .catch(() => {});
              }}>
              <Drawer.Navigator
                drawerContent={renderDrawer}
                // One screen, nothing to detach. With detaching on, iOS hosts
                // the screen in a UINavigationController, which adds the system
                // scroll-edge blur to the top of every scroll view.
                detachInactiveScreens={false}
                screenOptions={({route}) => ({
                  headerShown: false,
                  drawerType: 'slide',
                  // The whole chat screen opens the drawer, not just its edge;
                  // pushed screens keep their own back swipe.
                  swipeEnabled:
                    (getFocusedRouteNameFromRoute(route) ?? 'Chat') === 'Chat',
                  swipeEdgeWidth: width,
                  swipeMinDistance: 12,
                  // ANTICHAT M4: a swipe towards the start on a chat row
                  // belongs to the row (its archive / delete actions), so the
                  // drawer waits longer before it takes a closing swipe.
                  configureGestureHandler: gesture =>
                    // The drawer builds its pan with the builder API; Gesture
                    // Handler 3 types `PanGesture` as the hook API's object.
                    (gesture as unknown as LegacyPan).activeOffsetX([
                      -DRAWER_CLOSE_SWIPE_OFFSET,
                      5,
                    ]) as unknown as typeof gesture,
                  overlayColor: theme.colors.scrim,
                  drawerStyle: {
                    width: Math.min(
                      width * DRAWER_WIDTH_RATIO,
                      DRAWER_MAX_WIDTH,
                    ),
                    backgroundColor: theme.colors.drawer,
                  },
                  sceneStyle: {backgroundColor: theme.colors.background},
                })}>
                <Drawer.Screen name="Main" component={MainStack} />
              </Drawer.Navigator>
            </NavigationContainer>
          </FirstRunGate>
          {currentBackend() === 'real' ? <RealBackendHost /> : null}
          <HistoryOverlays />
          <ToastHost />
          {/* M12: write approvals, the Connect card, sign-in deep links. */}
          <ConnectorsHost
            // The chat draws the Connect card under the answer itself.
            inlineCards
            onOpenConnectors={() => {
              if (navigationRef.isReady()) {
                navigationRef.navigate('Main', {screen: 'Connectors'});
              }
            }}
          />
        </KeyboardProvider>
      </SafeAreaProvider>
    </GestureHandlerRootView>
  );
}

const styles = StyleSheet.create(theme => ({
  root: {
    flex: 1,
    backgroundColor: theme.colors.background,
  },
}));
