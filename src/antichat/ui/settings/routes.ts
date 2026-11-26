/** The screens M6 adds to the main stack. */
export type SettingsRoutes = {
  Settings: undefined;
  SettingsGeneral: undefined;
  SettingsLanguage: undefined;
  SettingsPersonalization: undefined;
  SettingsMemories: undefined;
  SettingsVoice: undefined;
  SettingsData: undefined;
  SettingsArchived: undefined;
  SettingsPrivacy: undefined;
  SettingsAbout: undefined;
  SettingsLicences: undefined;
  SettingsLicence: {name: string};
  SettingsAdvanced: undefined;
  Models: undefined;
  PhoneCapabilities: undefined;
  Storage: undefined;
};

export type SettingsRouteName = keyof SettingsRoutes;
