import React from 'react';
import {View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {usePort} from '../../adapters';
import type {VoicePort} from '../../engine/voice/port';
import {Icon, Toggle} from '../primitives';
import {Group, Row} from '../settings/components';
import {getVoicePort} from './port';
import {DICTATION_LANGUAGES, voiceStrings as s} from './strings';

/**
 * Settings > Voice, version 1: the language dictation listens for
 * (Automatic follows what is said) and punctuation.
 */
export function DictationSettings({
  voice = getVoicePort(),
}: {
  voice?: VoicePort;
}) {
  const settings = usePort(voice, port => port.settings);
  return (
    <View testID="dictation-settings" style={styles.list}>
      <Group>
        <Row
          testID="voice-opt-punctuation"
          title={s.picker.punctuation}
          trailing={
            <Toggle
              value={settings.punctuation}
              accessibilityLabel={s.picker.punctuation}
              onValueChange={punctuation => voice.updateSettings({punctuation})}
            />
          }
        />
      </Group>
      <View accessibilityRole="radiogroup">
        <Group title={s.dictationLanguage}>
          {DICTATION_LANGUAGES.map(language => {
            const selected = settings.language === language.tag;
            return (
              <Row
                key={language.tag}
                testID={`dictation-language-${language.tag}`}
                title={language.name}
                subtitle={
                  language.tag === 'auto' ? s.dictationAutomatic : undefined
                }
                trailing={
                  selected ? (
                    <Icon name="check" size={20} color="accent" />
                  ) : undefined
                }
                onPress={() => voice.updateSettings({language: language.tag})}
              />
            );
          })}
        </Group>
      </View>
    </View>
  );
}

const styles = StyleSheet.create(theme => ({
  list: {gap: theme.spacing.lg},
}));
