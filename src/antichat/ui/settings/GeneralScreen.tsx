import React from 'react';
import {View} from 'react-native';
import {observer} from 'mobx-react';
import {StyleSheet} from 'react-native-unistyles';

import {preferences} from '../../app/preferences';
import {useT} from '../../locales';
import {
  ACCENTS,
  ACCENT_NAMES,
  type AccentName,
  type ThemeMode,
} from '../../theme';
import {Icon, PressableScale, Text, haptics} from '../primitives';
import {Group, MenuRow, Row, SettingsPage, ToggleRow} from './components';
import {languageName} from './LanguageScreen';
import {useOpen} from './navigation';
import {settingsStore} from './store';

const MODES: ThemeMode[] = ['system', 'light', 'dark'];

/** General: how the app looks, its language, haptics. */
export const GeneralScreen = observer(function General() {
  const t = useT();
  const open = useOpen();
  return (
    <SettingsPage testID="settings-general-page" title={t('settings.general')}>
      <Group title={t('settings.general_.appearance')}>
        <MenuRow
          testID="theme-row"
          title={t('settings.general_.theme')}
          value={t(`appearance.${preferences.themeMode}`)}
          items={MODES.map(mode => ({
            id: mode,
            title: t(`appearance.${mode}`),
            checked: preferences.themeMode === mode,
          }))}
          onSelect={id => preferences.setThemeMode(id as ThemeMode)}
        />
        <View style={styles.accent}>
          <View style={styles.accentHead}>
            <Text>{t('settings.general_.accent')}</Text>
            <Text color="textSecondary">
              {t(`appearance.accents.${preferences.accent}`)}
            </Text>
          </View>
          <View style={styles.swatches} accessibilityRole="radiogroup">
            {ACCENT_NAMES.map(accent => (
              <Swatch
                key={accent}
                accent={accent}
                label={t(`appearance.accents.${accent}`)}
                selected={preferences.accent === accent}
              />
            ))}
          </View>
        </View>
      </Group>
      <Group>
        <Row
          testID="language-row"
          title={t('settings.general_.language')}
          value={languageName(t, settingsStore.language)}
          chevron
          onPress={() => open('SettingsLanguage')}
        />
        <ToggleRow
          testID="haptics-toggle"
          title={t('settings.general_.haptics')}
          subtitle={t('settings.general_.hapticsHint')}
          value={preferences.haptics}
          onValueChange={value => preferences.setHaptics(value)}
        />
      </Group>
    </SettingsPage>
  );
});

const Swatch = observer(function AccentSwatch({
  accent,
  label,
  selected,
}: {
  accent: AccentName;
  label: string;
  selected: boolean;
}) {
  return (
    <PressableScale
      testID={`accent-${accent}`}
      accessibilityRole="radio"
      accessibilityLabel={label}
      accessibilityState={{selected}}
      hitSlop={6}
      onPress={() => {
        haptics.selection();
        preferences.setAccent(accent);
      }}
      style={styles.ring(selected, accent)}>
      <View style={styles.swatch(accent)}>
        {selected ? (
          <Icon
            name="check"
            size={14}
            color={accent === 'neutral' ? 'background' : 'onAccent'}
            strokeWidth={3}
          />
        ) : null}
      </View>
    </PressableScale>
  );
});

const styles = StyleSheet.create(theme => ({
  accent: {
    gap: theme.spacing.md,
    paddingHorizontal: theme.spacing.lg,
    paddingVertical: theme.spacing.md + theme.spacing.xxs,
  },
  accentHead: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    gap: theme.spacing.md,
  },
  swatches: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: theme.spacing.sm,
  },
  // The ring is drawn in the swatch's own colour, not the active accent's.
  ring: (selected: boolean, accent: AccentName) => ({
    width: 36,
    height: 36,
    borderRadius: 18,
    alignItems: 'center',
    justifyContent: 'center',
    borderWidth: 2,
    borderColor: selected
      ? ACCENTS[accent][theme.scheme].accent
      : 'transparent',
  }),
  swatch: (accent: AccentName) => ({
    width: 26,
    height: 26,
    borderRadius: 13,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: ACCENTS[accent][theme.scheme].accent,
  }),
}));
