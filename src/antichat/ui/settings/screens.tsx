import React from 'react';

import {
  ManageModelsScreen,
  PhoneCapabilitiesScreen,
  StorageScreen,
} from '../models';
import {AboutScreen} from './AboutScreen';
import {AdvancedScreen} from './AdvancedScreen';
import {ArchivedChatsScreen} from './ArchivedChatsScreen';
import {DataControlsScreen} from './DataControlsScreen';
import {GeneralScreen} from './GeneralScreen';
import {LanguageScreen} from './LanguageScreen';
import {LicenceScreen, LicencesScreen} from './LicencesScreen';
import {MemoriesScreen} from './MemoriesScreen';
import {PersonalizationScreen} from './PersonalizationScreen';
import {PrivacyScreen} from './PrivacyScreen';
import type {SettingsRoutes} from './routes';
import {SettingsScreen} from './SettingsScreen';
import {VoiceScreen} from './VoiceScreen';

type ScreenComponent = React.ComponentType<any>;

const SCREENS: Record<keyof SettingsRoutes, ScreenComponent> = {
  Settings: SettingsScreen,
  SettingsGeneral: GeneralScreen,
  SettingsLanguage: LanguageScreen,
  SettingsPersonalization: PersonalizationScreen,
  SettingsMemories: MemoriesScreen,
  SettingsVoice: VoiceScreen,
  SettingsData: DataControlsScreen,
  SettingsArchived: ArchivedChatsScreen,
  SettingsPrivacy: PrivacyScreen,
  SettingsAbout: AboutScreen,
  SettingsLicences: LicencesScreen,
  SettingsLicence: LicenceScreen,
  SettingsAdvanced: AdvancedScreen,
  Models: ManageModelsScreen,
  PhoneCapabilities: PhoneCapabilitiesScreen,
  Storage: StorageScreen,
};

/**
 * M6's screens for the main stack:
 *
 *   <Stack.Navigator>
 *     …
 *     {settingsScreens(Stack.Screen)}
 *   </Stack.Navigator>
 */
export function settingsScreens(
  Screen: React.ComponentType<{name: any; component: ScreenComponent}>,
): React.ReactNode[] {
  return (Object.keys(SCREENS) as Array<keyof SettingsRoutes>).map(name => (
    <Screen key={name} name={name} component={SCREENS[name]} />
  ));
}
