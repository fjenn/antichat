import '../../../theme/unistyles';

import React, {useEffect, useRef, useState} from 'react';
import {ScrollView, View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import * as RNFS from '@dr.pogodin/react-native-fs';

import type {VoicePort} from '../../../engine/voice/port';
import {GlassSurface, Text, ToastHost} from '../../primitives';
import {DictationSettings} from '../DictationSettings';
import {
  DictationButton,
  DictationLayer,
  registerVoiceUi,
  useDictating,
} from '../register';
import {DemoVoice} from './DemoVoice';
import {
  HARNESS_DIR,
  createRealVoice,
  readConfig,
  type RealVoice,
} from './RealVoice';

/**
 * Dictation on one screen, mounted the way the composer mounts it
 * (`registerVoiceUi`, `DictationButton`, `DictationLayer`): the check screen
 * for the voice UI (served by dev/metro.voice-ui.config.js; not part of the
 * app). With `voice-harness/ui.json` on the device it runs on the real
 * engine with the microphone fed from the WAV fixtures (RealVoice.ts);
 * otherwise on the scripted DemoVoice.
 */
export function VoiceDevScreen() {
  const [setup, setSetup] = useState<{
    voice: VoicePort;
    real: RealVoice | null;
  } | null>(null);
  const [problem, setProblem] = useState('');
  useEffect(() => {
    let made: RealVoice | null = null;
    (async () => {
      const config = await readConfig();
      if (!config) {
        setSetup({voice: new DemoVoice(), real: null});
        return;
      }
      made = await createRealVoice(config);
      setSetup({voice: made.port, real: made});
    })().catch(err => setProblem(String(err)));
    return () => made?.dispose();
  }, []);
  if (!setup) {
    return (
      <View testID="voice-dev-loading" style={styles.screen}>
        <View style={styles.content}>
          <Text color={problem ? 'danger' : 'textSecondary'}>
            {problem || 'Loading…'}
          </Text>
        </View>
      </View>
    );
  }
  return <Screen {...setup} />;
}

function Screen({voice, real}: {voice: VoicePort; real: RealVoice | null}) {
  const [draft, setDraft] = useState('');
  const trace = useRef<Record<string, unknown>[]>([]);
  const dictating = useDictating(voice);

  const record = (entry: Record<string, unknown>) => {
    trace.current.push({at: Date.now(), ...entry});
    if (real) {
      RNFS.writeFile(
        `${HARNESS_DIR}/ui-trace.json`,
        JSON.stringify(trace.current),
        'utf8',
      ).catch(() => {});
    }
  };

  useEffect(
    () =>
      registerVoiceUi(
        {
          insertText: text => {
            setDraft(text);
            record({draft: text});
          },
        },
        voice,
      ),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [voice],
  );

  // The trace of what the port did, and the fixture "speaker": a sentence in
  // the chosen language is said when dictation starts listening.
  useEffect(() => {
    let last = '';
    let longest = '';
    const off = voice.subscribe(() => {
      const state = voice.dictation;
      if (
        state.status === 'listening' &&
        state.partial.length > longest.length
      ) {
        longest = state.partial;
      }
      if (state.status === last) {
        return;
      }
      record({
        dictation: state.status,
        language: voice.settings.language,
        ...(last === 'listening' ? {livePartial: longest} : {}),
        ...(state.status === 'failed' ? {error: state.error} : {}),
      });
      if (state.status === 'listening') {
        longest = '';
        const fixture =
          voice.settings.language === 'de' ? 'de-de-wetter' : 'en-us-capital';
        setTimeout(() => real?.say(fixture), 400);
      }
      last = state.status;
    });
    record({ready: real ? 'real' : 'demo'});
    return off;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [voice, real]);

  return (
    <View testID="voice-dev" style={styles.screen}>
      <ScrollView contentContainerStyle={styles.content}>
        <Text variant="title" testID="voice-dev-title">
          {real ? 'Dictation · real engine' : 'Dictation'}
        </Text>
        <DictationSettings voice={voice} />
      </ScrollView>
      <View style={styles.dock} pointerEvents="box-none">
        {dictating ? (
          <DictationLayer voice={voice} />
        ) : (
          <GlassSurface testID="composer" radius={28} style={styles.composer}>
            <Text
              testID="composer-text"
              color={draft ? 'textPrimary' : 'textTertiary'}
              numberOfLines={3}
              style={styles.field}>
              {draft || 'Ask anything'}
            </Text>
            <DictationButton voice={voice} />
          </GlassSurface>
        )}
      </View>
      <ToastHost />
    </View>
  );
}

const styles = StyleSheet.create((theme, rt) => ({
  screen: {flex: 1, backgroundColor: theme.colors.background},
  content: {
    gap: theme.spacing.xl,
    paddingTop: rt.insets.top + theme.spacing.lg,
    paddingHorizontal: theme.spacing.lg,
    paddingBottom: 200,
  },
  dock: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    gap: theme.spacing.sm,
    paddingHorizontal: theme.spacing.md,
    paddingBottom: Math.max(rt.insets.bottom, theme.spacing.md),
  },
  composer: {
    minHeight: theme.sizes.composerMinHeight,
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.xs,
    paddingHorizontal: theme.spacing.sm,
    paddingVertical: theme.spacing.sm,
  },
  field: {flex: 1, paddingHorizontal: theme.spacing.sm},
}));
