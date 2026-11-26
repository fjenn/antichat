import {talentRegistry} from '../../../services/talents/TalentRegistry';
import {
  ENGINE_INSTALL_ORDER,
  getEngine,
  installEngine,
  uninstallEngine,
  type EngineStep,
} from '../install';
import {
  clearRequestProviders,
  hasRequestProviders,
  listRequestProviders,
} from '../prompt/registry';
import {ConversationStore} from '../store/ConversationStore';
import {Db} from '../store/driver';
import {FakeUpstream} from '../store/__tests__/support/fakeUpstream';
import {openNodeSqlite} from '../store/__tests__/support/nodeDriver';
import {resetToolInstall} from '../tools/install';

jest.mock('@react-native-async-storage/async-storage', () => ({
  getItem: jest.fn().mockResolvedValue(null),
  setItem: jest.fn().mockResolvedValue(undefined),
  removeItem: jest.fn().mockResolvedValue(undefined),
}));

const mockConnectivity = {
  online: true,
  subscribe: jest.fn(() => () => undefined),
};
const mockStartConnectivity = jest.fn().mockResolvedValue(undefined);
jest.mock('../../adapters/connectivity', () => ({
  connectivity: mockConnectivity,
  startConnectivity: () => mockStartConnectivity(),
}));

let mockStore: ConversationStore;
let mockOpened: Promise<void> | null = null;
jest.mock('../../adapters/conversation', () => ({
  conversationAdapter: () => ({
    // As in the app: the database is opened (and migrated) on first use,
    // which is after the installer has registered every schema.
    store: async () => {
      await (mockOpened ??= mockStore.init());
      return mockStore;
    },
    setProject: jest.fn(),
    deleteSessions: jest.fn(),
  }),
}));

const mockModels = {
  engine: {
    deviceClass: 'E' as const,
    activeModelId: null,
    subscribe: jest.fn(() => () => undefined),
  },
  backend: {
    isVerified: jest.fn().mockResolvedValue(false),
    pathFor: jest.fn(() => '/models/e.gguf'),
    availableMemoryBytes: jest.fn().mockResolvedValue(8e9),
  },
  catalogStore: {catalog: {embedding: undefined}},
  start: jest.fn().mockResolvedValue(undefined),
  stop: jest.fn(),
};

describe('installEngine', () => {
  let close: () => void;

  beforeEach(async () => {
    clearRequestProviders();
    resetToolInstall();
    const driver = openNodeSqlite();
    close = () => driver.close();
    mockOpened = null;
    mockStore = new ConversationStore({
      db: new Db(driver),
      upstream: new FakeUpstream(),
    });
  });

  afterEach(() => {
    uninstallEngine();
    clearRequestProviders();
    close();
  });

  const install = async () => {
    const steps: EngineStep[] = [];
    const engine = await installEngine({
      modelRuntime: () => mockModels as never,
      onStep: step => steps.push(step),
    });
    return {engine, steps};
  };

  it('does nothing until it is called: upstream mode stays stock', () => {
    expect(hasRequestProviders()).toBe(false);
    expect(getEngine()).toBeNull();
  });

  it('runs the steps in the documented order, once', async () => {
    const {engine, steps} = await install();
    expect(steps).toEqual([...ENGINE_INSTALL_ORDER]);
    expect(engine.failed).toEqual({});
    expect(mockStartConnectivity).toHaveBeenCalledTimes(1);
    expect(mockModels.start).toHaveBeenCalledTimes(1);
    expect(await installEngine()).toBe(engine);
    expect(getEngine()).toBe(engine);
  });

  it('orders the request providers: prompt, skills, tools, project, memory, context', async () => {
    await install();
    const ids = listRequestProviders().map(provider => provider.id);
    const wanted = [
      'antichat.system-prompt',
      'antichat.skills',
      'antichat.tools',
      'antichat.project',
      'antichat.memory',
      'antichat.context',
    ];
    expect(ids.filter(id => wanted.includes(id))).toEqual(wanted);
    // Context fitting must see everything the others added.
    expect(ids[ids.length - 1]).toBe('antichat.context');
  });

  it('registers the memory tools as talents', async () => {
    await install();
    for (const name of ['save_memory', 'search_chats']) {
      expect(talentRegistry.get(name)).toBeDefined();
    }
  });

  it('removes every provider again', async () => {
    const {engine} = await install();
    engine.uninstall();
    expect(hasRequestProviders()).toBe(false);
    expect(mockModels.stop).toHaveBeenCalled();
  });
});
