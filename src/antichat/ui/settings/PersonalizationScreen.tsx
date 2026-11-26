import React, {useSyncExternalStore} from 'react';
import {View} from 'react-native';
import {observer} from 'mobx-react';
import {StyleSheet} from 'react-native-unistyles';

import {
  PERSONALITY_PRESETS,
  PERSONALIZATION_LIMITS,
  getPersonalization,
  setPersonalization,
  subscribePersonalization,
  type Dial,
  type PersonalityPreset,
  type PersonalizationSettings,
} from '../../engine/prompt/personalization';
import {MemorySettingsRows} from '../memory';
import {useT} from '../../locales';
import {Text} from '../primitives';
import {
  Group,
  MenuRow,
  Segmented,
  SettingsPage,
  TextArea,
  ToggleRow,
} from './components';
import {useOpen} from './navigation';

const PRESETS = Object.keys(PERSONALITY_PRESETS) as PersonalityPreset[];
const DIALS = ['warmth', 'enthusiasm', 'headersAndLists', 'emoji'] as const;
type DialName = (typeof DIALS)[number];

const DIAL_LABEL = {
  warmth: 'settings.personal.warmth',
  enthusiasm: 'settings.personal.enthusiasm',
  headersAndLists: 'settings.personal.headers',
  emoji: 'settings.personal.emoji',
} as const;

function subscribe(listener: () => void): () => void {
  return subscribePersonalization(listener);
}

/** The personalisation settings of the prompt engine (M7), kept current. */
export function usePersonalization(): PersonalizationSettings {
  return useSyncExternalStore(
    subscribe,
    getPersonalization,
    getPersonalization,
  );
}

/**
 * Personalization: how AntiChat talks, what it should know about the user,
 * and memory. Writes M7's schema directly, so what is set here is what the
 * system prompt is built from.
 */
export const PersonalizationScreen = observer(function Personalization() {
  const t = useT();
  const open = useOpen();
  const settings = usePersonalization();
  const dialOptions: ReadonlyArray<{id: Dial; label: string}> = [
    {id: 'less', label: t('settings.personal.less')},
    {id: 'default', label: t('settings.personal.default')},
    {id: 'more', label: t('settings.personal.more')},
  ];
  const off = !settings.enabled;

  return (
    <SettingsPage
      testID="settings-personalization-page"
      title={t('settings.personalization')}
      keyboard>
      <Group footer={t('settings.personal.enableHint')}>
        <ToggleRow
          testID="personalization-enabled"
          title={t('settings.personal.enable')}
          value={settings.enabled}
          onValueChange={enabled => setPersonalization({enabled})}
        />
      </Group>

      <View
        style={off ? styles.off : undefined}
        pointerEvents={off ? 'none' : 'auto'}
        accessibilityElementsHidden={off}
        importantForAccessibility={off ? 'no-hide-descendants' : 'auto'}>
        <View style={styles.sections}>
          <Group>
            <MenuRow
              testID="personality-preset"
              title={t('settings.personal.style')}
              value={t(`settings.personal.presets.${settings.preset}`)}
              items={PRESETS.map(preset => ({
                id: preset,
                title: t(`settings.personal.presets.${preset}`),
                subtitle: t(`settings.personal.presets.${preset}Hint`),
                checked: settings.preset === preset,
              }))}
              onSelect={id =>
                setPersonalization({preset: id as PersonalityPreset})
              }
            />
          </Group>

          <Group title={t('settings.personal.characteristics')}>
            {DIALS.map((dial: DialName) => (
              <View key={dial} style={styles.dial}>
                <Text style={styles.dialLabel}>{t(DIAL_LABEL[dial])}</Text>
                <Segmented
                  testID={`dial-${dial}`}
                  accessibilityLabel={t(DIAL_LABEL[dial])}
                  options={dialOptions}
                  value={settings[dial]}
                  onChange={value => setPersonalization({[dial]: value})}
                />
              </View>
            ))}
          </Group>

          <Group title={t('settings.personal.instructions')}>
            <TextArea
              testID="custom-instructions"
              value={settings.customInstructions}
              onChangeText={customInstructions =>
                setPersonalization({customInstructions})
              }
              placeholder={t('settings.personal.instructionsPlaceholder')}
              accessibilityLabel={t('settings.personal.instructions')}
              maxLength={PERSONALIZATION_LIMITS.customInstructions}
            />
          </Group>

          <Group
            title={t('settings.personal.aboutYou')}
            footer={t('settings.personal.aboutFooter')}>
            <TextArea
              testID="about-nickname"
              singleLine
              value={settings.nickname}
              onChangeText={nickname => setPersonalization({nickname})}
              placeholder={t('settings.personal.nicknamePlaceholder')}
              accessibilityLabel={t('settings.personal.nickname')}
              maxLength={PERSONALIZATION_LIMITS.nickname}
            />
            <TextArea
              testID="about-occupation"
              singleLine
              value={settings.occupation}
              onChangeText={occupation => setPersonalization({occupation})}
              placeholder={t('settings.personal.occupationPlaceholder')}
              accessibilityLabel={t('settings.personal.occupation')}
              maxLength={PERSONALIZATION_LIMITS.occupation}
            />
            <TextArea
              testID="about-more"
              value={settings.aboutYou}
              onChangeText={aboutYou => setPersonalization({aboutYou})}
              placeholder={t('settings.personal.morePlaceholder')}
              accessibilityLabel={t('settings.personal.more2')}
              maxLength={PERSONALIZATION_LIMITS.aboutYou}
            />
          </Group>
        </View>
      </View>

      {/* M9: the memory switches and the way to the manage screen. */}
      <MemorySettingsRows onManage={() => open('Memory' as never)} />
    </SettingsPage>
  );
});

const styles = StyleSheet.create(theme => ({
  sections: {
    gap: theme.spacing.xxl,
  },
  off: {
    opacity: 0.4,
  },
  dial: {
    minHeight: 54,
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'center',
    justifyContent: 'space-between',
    columnGap: theme.spacing.md,
    rowGap: theme.spacing.sm,
    paddingHorizontal: theme.spacing.lg,
    paddingVertical: theme.spacing.sm + theme.spacing.xxs,
  },
  dialLabel: {
    flexShrink: 1,
  },
}));
