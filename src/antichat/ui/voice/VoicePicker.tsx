import React, {useEffect, useState} from 'react';
import {View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {usePort} from '../../adapters';
import type {VoicePort} from '../../engine/voice/port';
import {ListRow, Text, Toggle, toast} from '../primitives';
import {formatBytes, voiceStrings as s} from './strings';

export interface VoicePickerProps {
  voice: VoicePort;
  /** Also show the voice-mode switches (Settings > Voice). */
  showOptions?: boolean;
}

/**
 * Settings > Voice: the short list of voices for this phone. A tap selects a
 * voice, downloading it first when needed (size shown, progress in place),
 * and says a sample with it.
 */
export function VoicePicker({voice, showOptions = true}: VoicePickerProps) {
  const voices = usePort(voice, port => port.voices);
  const voiceId = usePort(voice, port => port.voiceId);
  const settings = usePort(voice, port => port.settings);
  const [progress, setProgress] = useState<Record<string, number>>({});
  const active = usePort(voice, port => port.activeVoiceId);
  const selected =
    active ??
    voiceId ??
    voices.find(v => v.recommended && v.installed)?.id ??
    null;

  useEffect(
    () =>
      voice.onEvent(event => {
        if (event.type === 'voice_download') {
          setProgress(current => ({
            ...current,
            [event.voiceId]: event.progress,
          }));
        }
      }),
    [voice],
  );

  const choose = async (id: string) => {
    try {
      await voice.setVoice(id);
      setProgress(current => {
        const rest = {...current};
        delete rest[id];
        return rest;
      });
      await voice.pronounce(s.picker.preview);
    } catch {
      setProgress({});
      toast.show({message: s.picker.failed, kind: 'error'});
    }
  };

  return (
    <View testID="voice-picker" style={styles.list}>
      <View accessibilityRole="radiogroup">
        {voices.map(option => {
          const loading = progress[option.id];
          const subtitle =
            loading !== undefined
              ? s.picker.downloading(Math.round(loading * 100))
              : !option.installed
                ? s.picker.download(formatBytes(option.downloadBytes))
                : option.recommended
                  ? s.picker.recommended
                  : option.id.startsWith('system:')
                    ? s.picker.system
                    : option.languageTag === 'multi'
                      ? undefined
                      : option.languageTag;
          return (
            <ListRow
              key={option.id}
              testID={`voice-${option.id}`}
              title={option.displayName}
              subtitle={subtitle}
              selected={option.id === selected}
              disabled={loading !== undefined}
              trailing={
                option.id === selected ? (
                  <Text color="accent" accessibilityLabel="">
                    ✓
                  </Text>
                ) : undefined
              }
              onPress={() => {
                choose(option.id);
              }}
            />
          );
        })}
      </View>
      {showOptions ? (
        <View>
          <ListRow
            testID="voice-opt-bargein"
            title={s.picker.interrupt}
            trailing={
              <Toggle
                value={settings.bargeIn}
                accessibilityLabel={s.picker.interrupt}
                onValueChange={bargeIn => voice.updateSettings({bargeIn})}
              />
            }
          />
          <ListRow
            testID="voice-opt-fast"
            title={s.picker.fastReplies}
            trailing={
              <Toggle
                value={settings.fastReplies}
                accessibilityLabel={s.picker.fastReplies}
                onValueChange={fastReplies =>
                  voice.updateSettings({fastReplies})
                }
              />
            }
          />
          <ListRow
            testID="voice-opt-punctuation"
            title={s.picker.punctuation}
            trailing={
              <Toggle
                value={settings.punctuation}
                accessibilityLabel={s.picker.punctuation}
                onValueChange={punctuation =>
                  voice.updateSettings({punctuation})
                }
              />
            }
          />
        </View>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create(theme => ({
  list: {
    gap: theme.spacing.lg,
  },
}));
