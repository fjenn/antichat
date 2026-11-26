/**
 * Scroll/keyboard/streaming spike (milestone M0). One chat screen, two list
 * implementations behind the same handle, a scripted or real token source,
 * the auto-growing composer and the streaming haptic tick.
 */
import React, {useCallback, useEffect, useRef, useState} from 'react';
import {
  LogBox,
  Platform,
  Pressable,
  StyleSheet,
  Text,
  View,
  type LayoutChangeEvent,
} from 'react-native';
import {GestureHandlerRootView} from 'react-native-gesture-handler';
import {
  KeyboardGestureArea,
  KeyboardProvider,
} from 'react-native-keyboard-controller';
import {useSharedValue} from 'react-native-reanimated';
import {
  SafeAreaProvider,
  useSafeAreaInsets,
} from 'react-native-safe-area-context';

import {runAuto} from './auto';
import {Composer, COMPOSER_INPUT_ID, type ComposerHandle} from './Composer';
import {sendHaptic} from './haptics';
import type {SpikeUiConfig} from './launch';
import {ListA} from './ListA';
import {ListB} from './ListB';
import {JsFrameRecorder, useUiFrameRecorder, type FrameStats} from './perf';
import {SOURCE_LABEL, type SourceKind} from './sources';
import {chat, haptics, useChat, type RunSummary} from './store';
import type {ChatListHandle, ListKind} from './types';

// The LogBox toast sits on top of the composer and swallows its touches.
LogBox.ignoreAllLogs(true);

const SOURCES: SourceKind[] = ['script15', 'script30', 'script60', 'model'];

const line = (label: string, f: FrameStats) =>
  `${label} ${f.fps} fps · dropped ${f.dropped}/${f.frames} (${f.droppedPct}%) · hitches ${f.hitches} · max ${f.maxMs} ms`;

function Chip({
  label,
  active,
  onPress,
  testID,
}: {
  label: string;
  active?: boolean;
  onPress: () => void;
  testID?: string;
}) {
  return (
    <Pressable
      testID={testID}
      onPress={onPress}
      style={[styles.chip, active && styles.chipActive]}>
      <Text style={[styles.chipText, active && styles.chipTextActive]}>
        {label}
      </Text>
    </Pressable>
  );
}

function Screen({config}: {config: SpikeUiConfig}) {
  const insets = useSafeAreaInsets();
  const {messages, generating} = useChat();
  const [kind, setKind] = useState<ListKind>(config.list);
  const [source, setSource] = useState<SourceKind>(config.auto ?? 'script30');
  const [hapticsOn, setHapticsOn] = useState(true);
  const [conversation, setConversation] = useState(1);
  const [status, setStatus] = useState('');
  const [phase, setPhase] = useState('');

  const list = useRef<ChatListHandle>(null);
  const composer = useRef<ComposerHandle>(null);
  const composerHeight = useSharedValue(0);
  const js = useRef(new JsFrameRecorder()).current;
  const ui = useUiFrameRecorder();

  const onComposerLayout = useCallback(
    (event: LayoutChangeEvent) => {
      composerHeight.value = event.nativeEvent.layout.height;
    },
    [composerHeight],
  );

  const report = useCallback(
    (summary: RunSummary, frames: {js: FrameStats; ui: FrameStats}) => {
      const text = [
        `${summary.tokens} tok in ${summary.seconds.toFixed(1)} s = ${summary.tokensPerSecond.toFixed(1)} tok/s · ${summary.batcher.flushes} flushes (max ${summary.batcher.maxBatch}/flush) · ${summary.hapticTicks} ticks`,
        line('UI', frames.ui),
        line('JS', frames.js),
        summary.error ?? '',
      ]
        .filter(Boolean)
        .join('\n');
      setStatus(text);
      console.log(`[spike-ui] run ${JSON.stringify({summary, frames})}`);
    },
    [],
  );

  const send = useCallback(
    (text: string) => {
      sendHaptic();
      js.start();
      ui.start();
      chat.send(text, source).then(summary => {
        report(summary, {js: js.stop(), ui: ui.stop()});
      });
    },
    [js, report, source, ui],
  );

  const open = useCallback((seed: () => void) => {
    seed();
    setConversation(c => c + 1);
    return new Promise<void>(resolve => requestAnimationFrame(() => resolve()));
  }, []);

  useEffect(() => {
    haptics.enabled = hapticsOn;
  }, [hapticsOn]);

  // Unattended run requested at launch.
  const started = useRef(false);
  useEffect(() => {
    if (!config.auto || started.current) {
      return;
    }
    started.current = true;
    const timer = setTimeout(() => {
      runAuto(config.list, config.auto!, {
        list: () => list.current,
        composer: () => composer.current,
        open,
        setPhase,
        perfStart: () => {
          js.start();
          ui.start();
        },
        perfStop: () => ({js: js.stop(), ui: ui.stop()}),
      }).then(
        r =>
          setStatus(
            `auto: ${r.passed} passed, failed: ${(r.failed as string[]).join(', ') || 'none'}`,
          ),
        e => {
          setStatus(`auto failed: ${e?.message ?? e}`);
          console.log(`[spike-ui] ERROR ${e?.stack ?? e}`);
        },
      );
    }, 1500);
    return () => clearTimeout(timer);
  }, [config, js, open, ui]);

  const List = kind === 'A' ? ListA : ListB;
  const body = (
    <List
      key={`${kind}-${conversation}`}
      ref={list}
      messages={messages}
      generating={generating}
      composerHeight={composerHeight}
      conversationKey={`${conversation}`}
    />
  );

  return (
    <View style={[styles.root, {paddingTop: insets.top}]}>
      <View style={styles.header}>
        <View style={styles.chips}>
          <Chip
            testID="spike-list-A"
            label="A Legend"
            active={kind === 'A'}
            onPress={() => setKind('A')}
          />
          <Chip
            testID="spike-list-B"
            label="B ScrollView"
            active={kind === 'B'}
            onPress={() => setKind('B')}
          />
          {SOURCES.map(s => (
            <Chip
              key={s}
              testID={`spike-source-${s}`}
              label={SOURCE_LABEL[s]}
              active={source === s}
              onPress={() => setSource(s)}
            />
          ))}
          <Chip
            testID="spike-seed"
            label="Old chat"
            onPress={() => open(() => chat.seed(12))}
          />
          <Chip
            testID="spike-seed-long"
            label="200 msgs"
            onPress={() => open(() => chat.seed(100))}
          />
          <Chip
            testID="spike-new"
            label="New"
            onPress={() => open(() => chat.reset())}
          />
          <Chip
            testID="spike-haptics"
            label={hapticsOn ? 'Haptics on' : 'Haptics off'}
            active={hapticsOn}
            onPress={() => setHapticsOn(v => !v)}
          />
        </View>
        {phase || status ? (
          <Text testID="spike-status" style={styles.status}>
            {[phase, status].filter(Boolean).join('\n')}
          </Text>
        ) : null}
      </View>
      {Platform.OS === 'android' ? (
        <KeyboardGestureArea
          style={styles.body}
          interpolator="ios"
          offset={56}
          textInputNativeID={COMPOSER_INPUT_ID}>
          {body}
        </KeyboardGestureArea>
      ) : (
        <View style={styles.body}>{body}</View>
      )}
      <Composer
        ref={composer}
        generating={generating}
        onSend={send}
        onStop={chat.stop}
        onLayout={onComposerLayout}
      />
    </View>
  );
}

export function SpikeUIScreen({config}: {config: SpikeUiConfig}) {
  return (
    <GestureHandlerRootView style={styles.root}>
      <SafeAreaProvider>
        <KeyboardProvider statusBarTranslucent navigationBarTranslucent>
          <Screen config={config} />
        </KeyboardProvider>
      </SafeAreaProvider>
    </GestureHandlerRootView>
  );
}

const styles = StyleSheet.create({
  root: {flex: 1, backgroundColor: '#fff'},
  header: {
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: '#e0e0e0',
  },
  chips: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    paddingHorizontal: 8,
    paddingVertical: 6,
    gap: 6,
  },
  chip: {
    paddingHorizontal: 10,
    paddingVertical: 6,
    borderRadius: 14,
    backgroundColor: '#f1f1f1',
  },
  chipActive: {backgroundColor: '#0d0d0d'},
  chipText: {fontSize: 13, color: '#0d0d0d'},
  chipTextActive: {color: '#fff'},
  status: {
    fontSize: 11,
    lineHeight: 15,
    color: '#444',
    paddingHorizontal: 10,
    paddingBottom: 6,
  },
  body: {flex: 1},
});
