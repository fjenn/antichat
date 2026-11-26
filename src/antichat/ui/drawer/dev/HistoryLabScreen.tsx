import React, {useState, useSyncExternalStore} from 'react';
import {ScrollView, View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {getPorts, usePort} from '../../../adapters';
import {
  historyBackend,
  switchHistoryBackend,
} from '../../../adapters/historyBackend';
import {ScreenHeader} from '../../../app/screens/ScreenHeader';
import {useT} from '../../../locales';
import {
  deviceUnlock,
  keychainUnlock,
  setDeviceUnlock,
  type DeviceUnlock,
} from '../../chatmenu/deviceUnlock';
import {lockState} from '../../chatmenu/lockState';
import {Button, Chip, Text} from '../../primitives';
import {perfProbe} from './perfProbe';
import {seedHistory} from './seed';

const PASS: DeviceUnlock = {
  available: async () => true,
  authenticate: async () => 'ok',
};
const FAIL: DeviceUnlock = {
  available: async () => true,
  authenticate: async () => 'cancelled',
};

/**
 * Debug builds only: choose the chat-list backend, fill the real store with
 * a test history, stand in for Face ID on a simulator, and measure drawer
 * scrolling. Nothing here is translated; it never ships.
 */
export function HistoryLabScreen() {
  const t = useT();
  const {conversations} = getPorts();
  const count = usePort(conversations, port => port.conversations.length);
  const archived = usePort(conversations, port => port.archived().length);
  const [status, setStatus] = useState('Idle');
  const [busy, setBusy] = useState(false);
  const [unlock, setUnlock] = useState<'system' | 'pass' | 'fail'>(
    deviceUnlock() === PASS
      ? 'pass'
      : deviceUnlock() === FAIL
        ? 'fail'
        : 'system',
  );
  const phase = useSyncExternalStore(
    perfProbe.subscribe,
    perfProbe.phase,
    perfProbe.phase,
  );
  const result = useSyncExternalStore(
    perfProbe.subscribe,
    perfProbe.last,
    perfProbe.last,
  );
  const real = historyBackend() === 'real';

  const seed = (n: number, batch: string) => async () => {
    setBusy(true);
    const started = Date.now();
    try {
      const added = await seedHistory(
        n,
        done => setStatus(`Adding ${done} / ${n}`),
        {batch},
      );
      setStatus(
        `Done: added ${added} in ${((Date.now() - started) / 1000).toFixed(1)} s`,
      );
    } catch (error) {
      setStatus(`Failed: ${String((error as Error)?.message ?? error)}`);
    } finally {
      setBusy(false);
    }
  };

  const chooseUnlock = (mode: 'system' | 'pass' | 'fail') => {
    setUnlock(mode);
    setDeviceUnlock(
      mode === 'pass' ? PASS : mode === 'fail' ? FAIL : keychainUnlock,
    );
    lockState.lockAll();
  };

  return (
    <View testID="history-lab" style={styles.screen}>
      <ScreenHeader title={t('historyLab.title')} />
      <ScrollView contentContainerStyle={styles.content}>
        <Section title="Chat list backend">
          <View style={styles.wrap}>
            <Chip
              testID="lab-backend-real"
              label="Real store"
              selected={real}
              onPress={() => switchHistoryBackend('real').catch(() => {})}
            />
            <Chip
              testID="lab-backend-fake"
              label="Fake"
              selected={!real}
              onPress={() => switchHistoryBackend('fake').catch(() => {})}
            />
          </View>
          <Text testID="lab-count" variant="callout" color="textSecondary">
            {`${count} chats, ${archived} archived`}
          </Text>
        </Section>

        <Section title="Test history (real store)">
          <View style={styles.wrap}>
            <Button
              testID="lab-seed-24"
              label="Add 24"
              variant="secondary"
              disabled={busy || !real}
              onPress={seed(24, 'sample')}
            />
            <Button
              testID="lab-seed-2000"
              label="Add 2,000"
              variant="secondary"
              disabled={busy || !real}
              onPress={seed(2000, 'bulk')}
            />
            <Button
              testID="lab-clear"
              label="Delete all"
              variant="destructive"
              disabled={busy}
              onPress={() => {
                setBusy(true);
                conversations
                  .removeAll()
                  .then(() => setStatus('Done: deleted all'))
                  .catch(() => setStatus('Failed: delete all'))
                  .finally(() => setBusy(false));
              }}
            />
          </View>
          <Text testID="lab-status" variant="callout" color="textSecondary">
            {status}
          </Text>
        </Section>

        <Section title="Device unlock">
          <View style={styles.wrap}>
            <Chip
              testID="lab-unlock-system"
              label="System prompt"
              selected={unlock === 'system'}
              onPress={() => chooseUnlock('system')}
            />
            <Chip
              testID="lab-unlock-pass"
              label="Always pass"
              selected={unlock === 'pass'}
              onPress={() => chooseUnlock('pass')}
            />
            <Chip
              testID="lab-unlock-fail"
              label="Always fail"
              selected={unlock === 'fail'}
              onPress={() => chooseUnlock('fail')}
            />
          </View>
        </Section>

        <Section title="Drawer scroll">
          <Button
            testID="lab-perf-arm"
            label={
              phase === 'armed'
                ? 'Armed: scroll the drawer'
                : phase === 'recording'
                  ? 'Recording'
                  : 'Record the next drawer scroll'
            }
            variant="secondary"
            disabled={phase !== 'idle'}
            onPress={() => perfProbe.arm()}
          />
          {result ? (
            <Text testID="lab-perf-result" variant="footnote" selectable>
              {`${result.rows} rows\nUI ${result.ui.fps} fps, dropped ${result.ui.dropped}/${result.ui.frames} (${result.ui.droppedPct}%), hitches ${result.ui.hitches}, max ${result.ui.maxMs} ms, p95 ${result.ui.p95Ms} ms\nJS ${result.js.fps} fps, dropped ${result.js.dropped}/${result.js.frames} (${result.js.droppedPct}%), hitches ${result.js.hitches}, max ${result.js.maxMs} ms, p95 ${result.js.p95Ms} ms`}
            </Text>
          ) : null}
        </Section>
      </ScrollView>
    </View>
  );
}

function Section({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <View style={styles.section}>
      <Text variant="footnote" color="textSecondary" accessibilityRole="header">
        {title}
      </Text>
      {children}
    </View>
  );
}

const styles = StyleSheet.create((theme, rt) => ({
  screen: {
    flex: 1,
    backgroundColor: theme.colors.background,
  },
  content: {
    gap: theme.spacing.xxl,
    paddingHorizontal: theme.spacing.xl,
    paddingBottom: rt.insets.bottom + theme.spacing.xxl,
  },
  section: {
    gap: theme.spacing.md,
  },
  wrap: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: theme.spacing.sm,
  },
}));
