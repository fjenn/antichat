import React, {useEffect, useState} from 'react';
import {View} from 'react-native';
import Animated, {FadeOut, useReducedMotion} from 'react-native-reanimated';
import {observer} from 'mobx-react';
import {StyleSheet} from 'react-native-unistyles';

import {getPorts, usePort} from '../../adapters';
import {loadPersonalization} from '../../engine/prompt/personalization';
import {useT} from '../../locales';
import {
  formatBytes,
  lineup,
  modelCoordinator,
  onFirstModelReady,
  plainName,
} from '../models';
import {haptics} from '../primitives';
import {settingsStore} from '../settings/store';
import {notifyAssistantReady} from './notifications';
import {PickScreen} from './PickScreen';
import {WelcomeScreen} from './WelcomeScreen';

/**
 * Wraps the app. A new install sees the welcome screen once; "Get started"
 * shows the model picked for this phone, and its Download removes the cover:
 * the chat underneath is usable at once, with the download running. "Other
 * options" opens the model store instead. Every later launch goes straight
 * to the chat.
 *
 * It also starts what M6 owns at launch: the model coordinator and the
 * stored settings.
 */
export const FirstRunGate = observer(function Gate({
  children,
  onOpenStore,
}: {
  children: React.ReactNode;
  /** Opens the model store (first run's "Other options"). */
  onOpenStore?: () => void;
}) {
  const t = useT();
  const [step, setStep] = useState<'welcome' | 'pick'>('welcome');
  const coordinator = modelCoordinator();
  const {prefs} = coordinator;
  const reduceMotion = useReducedMotion();
  const ports = getPorts();
  const online = usePort(ports.connectivity, port => port.online);
  const targetBytes = usePort(
    ports.model,
    () => coordinator.target()?.downloadBytes,
  );
  // Re-render on engine changes so the pick card fills in when known.
  const pick = usePort(ports.model, port => {
    const target = coordinator.target();
    return target
      ? {...target, name: plainName(t, target, lineup(port))}
      : undefined;
  });
  useEffect(() => {
    onFirstModelReady((_name, modelId) => {
      haptics.success();
      notifyAssistantReady(modelId).catch(() => {});
    });
    settingsStore.connect({
      applyVoice: voiceId => {
        getPorts()
          .voice.setVoice(voiceId)
          .catch(() => {});
      },
    });
    settingsStore.load().catch(() => {});
    loadPersonalization().catch(() => {});
    coordinator.boot().catch(() => {});
    return () => onFirstModelReady(null);
  }, [coordinator]);

  if (!prefs.loaded) {
    return <View style={styles.blank} />;
  }
  const showWelcome = !prefs.started;
  return (
    <View style={styles.root}>
      <View
        style={styles.root}
        accessibilityElementsHidden={showWelcome}
        importantForAccessibility={
          showWelcome ? 'no-hide-descendants' : 'auto'
        }>
        {children}
      </View>
      {showWelcome ? (
        <Animated.View
          style={styles.cover}
          exiting={reduceMotion ? undefined : FadeOut.duration(260)}>
          {step === 'welcome' ? (
            <WelcomeScreen
              offline={!online}
              downloadSize={targetBytes ? formatBytes(targetBytes) : undefined}
              onStart={() => setStep('pick')}
            />
          ) : (
            <PickScreen
              model={pick}
              name={pick?.name}
              offline={!online}
              onDownload={() => coordinator.getStarted()}
              onOther={() => {
                // Into the chat with nothing downloading; the store's first
                // Download picks the model.
                coordinator.prefs.set({started: true, holdDownload: true});
                onOpenStore?.();
              }}
            />
          )}
        </Animated.View>
      ) : null}
    </View>
  );
});

const styles = StyleSheet.create(theme => ({
  root: {
    flex: 1,
  },
  blank: {
    flex: 1,
    backgroundColor: theme.colors.background,
  },
  cover: {
    ...StyleSheet.absoluteFillObject,
    backgroundColor: theme.colors.background,
  },
}));
