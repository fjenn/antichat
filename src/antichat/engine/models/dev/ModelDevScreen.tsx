/**
 * Model engine dev screen (M5). Debug builds only; see config.ts.
 *
 * Shows what the engine decided for this phone (class, memory budget,
 * capability map, every model's state) and runs the first-run path:
 * classify -> select -> download -> verify -> load -> generate a sentence.
 */
import {observer} from 'mobx-react';
import React, {useEffect, useMemo, useState} from 'react';
import {
  Pressable,
  SafeAreaView,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import {connectivity} from '../../../adapters/connectivity';
import type {ModelRuntime} from '../../../adapters/model';
import type {CapabilityMap} from '../capabilities';
import type {ModelView} from '../port';

import type {ModelDevConfig} from './config';
import {DevLog} from './devLog';
import {runLab} from './lab';
import {createDevRuntime, generateSentence, runFirstRun} from './runner';

const GB = 1024 ** 3;
const gb = (bytes?: number) =>
  bytes === undefined ? '?' : `${(bytes / GB).toFixed(2)} GB`;

const describeState = (view: ModelView): string => {
  const state = view.state;
  switch (state.status) {
    case 'downloading': {
      const {receivedBytes, totalBytes, bytesPerSecond} = state.progress;
      const rate = bytesPerSecond
        ? ` · ${(bytesPerSecond / 1e6).toFixed(1)} MB/s`
        : '';
      const pause = state.paused ? ` · paused (${state.pauseReason})` : '';
      return `downloading ${gb(receivedBytes)} / ${gb(totalBytes)}${rate}${pause}`;
    }
    case 'verifying':
      return `verifying ${(state.fraction * 100).toFixed(0)}%`;
    case 'loading':
      return state.attempt
        ? `loading (${state.attempt.kind}, ${state.attempt.index + 1}/${state.attempt.total})`
        : 'loading';
    case 'loaded':
      return `loaded · ${state.info.backend} · ctx ${state.info.contextSize} · ${
        state.info.vision ? 'vision' : 'text'
      } · ${state.info.attempt}${state.info.degraded ? ' (fallback)' : ''}${
        state.info.tokensPerSecond
          ? ` · ${state.info.tokensPerSecond.toFixed(1)} tok/s`
          : ''
      }`;
    case 'failed':
      return `failed: ${state.reason} (${state.stage})${
        state.detail ? ` · ${state.detail}` : ''
      }`;
    default:
      return state.status;
  }
};

const capabilityLines = (map: CapabilityMap): string[] => {
  const lines: string[] = [];
  for (const [key, value] of Object.entries(map)) {
    if (value && typeof value === 'object' && 'available' in value) {
      lines.push(`${key}: ${value.available ? 'yes' : 'no'}`);
    } else if (typeof value !== 'object') {
      lines.push(`${key}: ${String(value)}`);
    }
  }
  return lines;
};

const Button = ({label, onPress}: {label: string; onPress: () => void}) => (
  <Pressable
    accessibilityRole="button"
    testID={`m5-${label.toLowerCase().replace(/\s+/g, '-')}`}
    onPress={onPress}
    style={({pressed}) => [styles.button, pressed && styles.pressed]}>
    <Text style={styles.buttonText}>{label}</Text>
  </Pressable>
);

const Body = observer(
  ({
    runtime,
    config,
    log,
  }: {
    runtime: ModelRuntime;
    config: ModelDevConfig;
    log: DevLog;
  }) => {
    const {engine} = runtime;
    const [, redraw] = useState(0);
    const [output, setOutput] = useState('');
    useEffect(() => log.subscribe(() => redraw(n => n + 1)), [log]);

    const device = engine.device;
    const run = (work: () => Promise<unknown>) => () => {
      work().catch(error => log.event('ui_error', {error: String(error)}));
    };

    return (
      <ScrollView contentContainerStyle={styles.content}>
        <Text style={styles.title}>Model engine (M5 dev)</Text>
        <Text testID="m5-connectivity" style={styles.line}>
          Network: {connectivity.online ? 'online' : 'OFFLINE'} ·{' '}
          {connectivity.kind}
          {connectivity.metered ? ' · metered' : ''}
        </Text>

        <Text style={styles.heading}>Device</Text>
        {device ? (
          <>
            <Text testID="m5-class" style={styles.line}>
              Class {device.deviceClass} (memory {device.memoryClass}, chip{' '}
              {device.chipClass}, upstream tier {device.upstreamTier})
            </Text>
            <Text style={styles.line}>
              RAM {gb(device.snapshot.totalRamBytes)} · available at launch{' '}
              {gb(device.snapshot.availableBytes)} · budget{' '}
              {gb(device.budget.availableBytes)} ({device.budget.source})
            </Text>
            <Text style={styles.line}>
              {device.snapshot.machine ?? device.snapshot.socModel ?? ''} ·{' '}
              {device.gpu.backend}
              {device.gpu.reason ? ` (${device.gpu.reason})` : ''} · up to{' '}
              {device.gpu.maxGpuLayers} GPU layers
            </Text>
          </>
        ) : (
          <Text style={styles.line}>Not initialised ({engine.phase})</Text>
        )}

        <Text style={styles.heading}>What this phone can do</Text>
        {engine.capabilities ? (
          capabilityLines(engine.capabilities).map(line => (
            <Text key={line} style={styles.line}>
              {line}
            </Text>
          ))
        ) : (
          <Text style={styles.line}>-</Text>
        )}

        <View style={styles.row}>
          <Button label="Initialize" onPress={run(() => runtime.start())} />
          <Button
            label="Get started"
            onPress={run(() => runFirstRun(runtime, config, log))}
          />
          <Button label="Unload" onPress={run(() => engine.unload())} />
          <Button
            label="Generate"
            onPress={run(async () => {
              setOutput('...');
              setOutput(
                await generateSentence(
                  runtime,
                  log,
                  config.prompt ?? 'Write one sentence about the sea.',
                  config.maxTokens ?? 64,
                ),
              );
            })}
          />
          <Button
            label="Memory warning"
            onPress={run(() =>
              engine.onMemoryPressure('critical', {generating: false, aux: []}),
            )}
          />
        </View>
        {output ? (
          <Text testID="m5-output" style={styles.output}>
            {output}
          </Text>
        ) : null}

        <Text style={styles.heading}>Models</Text>
        {engine.models.map(view => (
          <View key={view.id} style={styles.model}>
            <Text style={styles.modelName}>
              {view.displayName}
              {view.recommended ? ' · recommended' : ''}
              {view.unrestricted ? ' · unrestricted' : ''}
              {view.supported ? '' : ' · not for this phone'}
            </Text>
            <Text testID={`m5-state-${view.id}`} style={styles.line}>
              {view.id} · {gb(view.downloadBytes)} · {describeState(view)}
            </Text>
            {view.supported ? (
              <View style={styles.row}>
                <Button
                  label="Download"
                  onPress={run(() => engine.download(view.id))}
                />
                <Button label="Pause" onPress={() => engine.pause(view.id)} />
                <Button
                  label="Resume"
                  onPress={run(() => engine.resume(view.id))}
                />
                <Button
                  label="Load"
                  onPress={run(() => engine.load(view.id))}
                />
                <Button
                  label="Retry"
                  onPress={run(() => engine.retry(view.id))}
                />
                <Button
                  label="Remove"
                  onPress={run(() => engine.remove(view.id))}
                />
              </View>
            ) : null}
          </View>
        ))}

        <Text style={styles.heading}>Notices</Text>
        {engine.notices.length === 0 ? (
          <Text style={styles.line}>-</Text>
        ) : (
          engine.notices.map(notice => (
            <View key={notice.id} style={styles.row}>
              <Text style={styles.line}>{JSON.stringify(notice)}</Text>
              {notice.needsAnswer ? (
                <Button
                  label="Accept"
                  onPress={run(() => engine.answerNotice(notice.id, true))}
                />
              ) : null}
              <Button
                label="Dismiss"
                onPress={() => engine.dismissNotice(notice.id)}
              />
            </View>
          ))
        )}

        <Text style={styles.heading}>Log</Text>
        {log.lines.slice(-25).map((line, index) => (
          <Text key={`${index}-${line.length}`} style={styles.log}>
            {line.slice(0, 400)}
          </Text>
        ))}
      </ScrollView>
    );
  },
);

export function ModelDevScreen({config}: {config: ModelDevConfig}) {
  const log = useMemo(() => new DevLog(), []);
  const [runtime, setRuntime] = useState<ModelRuntime | null>(null);

  useEffect(() => {
    let cancelled = false;
    log.event('dev_launch', {config});
    if (config.auto === 'lab' && config.lab) {
      runLab(config.lab, log).catch(error =>
        log.event('lab_error', {error: String(error)}),
      );
      return;
    }
    createDevRuntime(config, log).then(created => {
      if (cancelled) {
        return;
      }
      setRuntime(created);
      if (config.auto === 'firstRun') {
        runFirstRun(created, config, log);
      } else {
        created
          .start()
          .catch(error => log.event('start_error', {error: String(error)}));
      }
    });
    return () => {
      cancelled = true;
    };
  }, [config, log]);

  return (
    <SafeAreaView style={styles.screen}>
      {runtime ? (
        <Body runtime={runtime} config={config} log={log} />
      ) : (
        <LabView log={log} />
      )}
    </SafeAreaView>
  );
}

function LabView({log}: {log: DevLog}) {
  const [, redraw] = useState(0);
  useEffect(() => log.subscribe(() => redraw(n => n + 1)), [log]);
  return (
    <ScrollView contentContainerStyle={styles.content}>
      <Text style={styles.title}>Model engine (M5 dev)</Text>
      {log.lines.slice(-40).map((line, index) => (
        <Text key={`${index}-${line.length}`} style={styles.log}>
          {line.slice(0, 400)}
        </Text>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: {flex: 1, backgroundColor: '#ffffff'},
  content: {padding: 16, paddingBottom: 48},
  title: {fontSize: 20, fontWeight: '600', color: '#111111', marginBottom: 8},
  heading: {fontSize: 15, fontWeight: '600', color: '#111111', marginTop: 16},
  line: {fontSize: 13, color: '#333333', marginTop: 2},
  log: {fontSize: 10, color: '#555555', marginTop: 2},
  output: {fontSize: 14, color: '#111111', marginTop: 8},
  row: {flexDirection: 'row', flexWrap: 'wrap', alignItems: 'center'},
  model: {marginTop: 10},
  modelName: {fontSize: 14, fontWeight: '500', color: '#111111'},
  button: {
    backgroundColor: '#ececec',
    borderRadius: 8,
    paddingHorizontal: 10,
    paddingVertical: 6,
    marginRight: 6,
    marginTop: 6,
  },
  pressed: {opacity: 0.6},
  buttonText: {fontSize: 13, color: '#111111'},
});
