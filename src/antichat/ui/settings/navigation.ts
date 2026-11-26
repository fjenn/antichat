import {useCallback} from 'react';
import {useNavigation} from '@react-navigation/native';

import type {SettingsRoutes} from './routes';

type WithoutParams = {
  [Name in keyof SettingsRoutes]: SettingsRoutes[Name] extends undefined
    ? Name
    : never;
}[keyof SettingsRoutes];

/** `open('SettingsGeneral')`: push one of M6's screens. */
export function useOpen(): {
  (screen: WithoutParams): void;
  <Name extends keyof SettingsRoutes>(
    screen: Name,
    params: SettingsRoutes[Name],
  ): void;
} {
  const navigation = useNavigation();
  return useCallback(
    (screen: keyof SettingsRoutes, params?: object) => {
      (navigation.navigate as (name: string, params: object) => void)('Main', {
        screen,
        params,
      });
    },
    [navigation],
  );
}
