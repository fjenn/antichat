import type {NavigatorScreenParams} from '@react-navigation/native';

import type {MemoryParams} from '../ui/memory';
import type {SettingsRoutes} from '../ui/settings/routes';

export type MainStackParams = {
  Chat: undefined;
  Gallery: undefined;
  /** ANTICHAT M4 */
  ArchivedChats: undefined;
  /** ANTICHAT M4, debug builds: seed and inspect the history. */
  HistoryLab: undefined;
  /** M12: Settings › Connectors (`ui/connectors`). */
  Connectors: undefined;
  // M6: Settings and the screens under it, Models, Storage.
} & SettingsRoutes &
  // M9: the memory screen.
  MemoryParams;

export type DrawerParams = {
  Main: NavigatorScreenParams<MainStackParams>;
};

declare global {
  namespace ReactNavigation {
    interface RootParamList extends DrawerParams {}
  }
}
