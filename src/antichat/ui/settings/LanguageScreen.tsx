import React from 'react';
import {observer} from 'mobx-react';

import {availableLocales, useT, type Translate} from '../../locales';
import {Icon} from '../primitives';
import {Group, Row, SettingsPage} from './components';
import {settingsStore} from './store';

/** A language named in itself ("Deutsch"), as language pickers do. */
function nativeName(tag: string): string {
  try {
    const name = new Intl.DisplayNames([tag], {type: 'language'}).of(tag);
    if (name) {
      return name.charAt(0).toLocaleUpperCase(tag) + name.slice(1);
    }
  } catch {
    // No Intl data for the tag.
  }
  return tag === 'en' ? 'English' : tag;
}

export function languageName(t: Translate, language: string): string {
  return language === 'system'
    ? t('settings.general_.languageSystem')
    : nativeName(language);
}

/** Language: follow the phone, or pick one the app has strings for. */
export const LanguageScreen = observer(function Language() {
  const t = useT();
  const options = ['system', ...availableLocales()];
  return (
    <SettingsPage
      testID="settings-language-page"
      title={t('settings.general_.language')}>
      <Group footer={t('settings.general_.languageFooter')}>
        {options.map(option => (
          <Row
            key={option}
            testID={`language-${option}`}
            title={languageName(t, option)}
            trailing={
              settingsStore.language === option ? (
                <Icon name="check" size={18} />
              ) : undefined
            }
            onPress={() => settingsStore.setLanguage(option)}
          />
        ))}
      </Group>
    </SettingsPage>
  );
});
