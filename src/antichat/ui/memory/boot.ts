/**
 * The whole start-up in one call, for the app root: opens antichat.db
 * through the conversation adapter, installs the memory engine and puts it
 * behind the memory screen and the chat components.
 *
 *   useEffect(() => { connectMemory().catch(() => {}); }, []);
 *
 * Imports upstream's stores, so it is required lazily and never from Jest.
 * An integration that installs the engine itself calls `registerMemoryUi`
 * instead.
 */
import {conversationAdapter} from '../../adapters/conversation';
import {
  installMemoryEngine,
  registerMemorySchemas,
} from '../../engine/memory/install';
import type {DeviceClass} from '../../engine/prompt/types';
import {registerMemoryUi} from './register';

let connecting: Promise<() => void> | null = null;

export function connectMemory(
  options: {deviceClass?: () => DeviceClass | undefined} = {},
): Promise<() => void> {
  connecting ??= (async () => {
    registerMemorySchemas();
    const store = await conversationAdapter().store();
    const engine = await installMemoryEngine({
      db: store.db,
      chats: store,
      deviceClass: options.deviceClass,
    });
    const unregister = registerMemoryUi({engine});
    return () => {
      unregister();
      connecting = null;
    };
  })();
  connecting.catch(() => {
    connecting = null;
  });
  return connecting;
}
