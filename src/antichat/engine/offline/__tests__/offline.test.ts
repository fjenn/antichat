import '../../../testing/setup';

import AsyncStorage from '@react-native-async-storage/async-storage';

import type {ApiCompletionParams} from '../../../../utils/completionTypes';
import {
  clearRequestProviders,
  registerRequestProvider,
} from '../../prompt/registry';
import {
  applyRequestSeam,
  getLastSentRequest,
  setSeamEnvironment,
} from '../../prompt/seam';
import type {ToolDefinition} from '../../prompt/types';
import {
  LOCATION_OFF_TEXT,
  createLocationTool,
  setLocationAllowed,
} from '../../tools/builtin/location';
import {
  OfflineChats,
  allowedOffline,
  chatOfTurn,
  isOfflineChat,
  offlineChats,
} from '..';

const tool = (name: string): ToolDefinition =>
  ({
    type: 'function',
    function: {name, description: name, parameters: {}},
  }) as ToolDefinition;

jest.mock('../../../../store', () => ({
  chatSessionStore: {activeSessionId: 'offline-1'},
  modelStore: {},
}));

describe('offline chats', () => {
  beforeEach(async () => {
    await AsyncStorage.clear();
    offlineChats.reset();
  });

  it('remembers which chats are offline across a restart', async () => {
    const first = new OfflineChats();
    first.mark('a');
    await new Promise(resolve => setTimeout(resolve, 0));
    const second = new OfflineChats();
    await second.load();
    expect(second.has('a')).toBe(true);
    expect(second.has('b')).toBe(false);
    expect(second.has(undefined)).toBe(false);
  });

  it('lets only local tools that write no memory through', () => {
    const kinds: Record<string, 'local' | 'online'> = {
      calculator: 'local',
      gmail_send: 'online',
    };
    const kindOf = (name: string) => kinds[name];
    expect(allowedOffline('calculator', kindOf)).toBe(true);
    expect(allowedOffline('search_chats', kindOf)).toBe(true);
    expect(allowedOffline('gmail_send', kindOf)).toBe(false);
    [
      'web_search',
      'read_url',
      'weather',
      'get_location',
      'save_memory',
    ].forEach(name => expect(allowedOffline(name, kindOf)).toBe(false));
  });

  it('claims the id of the chat being started while armed', () => {
    const chats = new OfflineChats();
    expect(chats.claim('old')).toBe(false);
    chats.arm();
    expect(chats.claim(undefined)).toBe(false);
    expect(chats.claim('new')).toBe(true);
    // Only the first chat: the next one is a normal chat again.
    expect(chats.claim('other')).toBe(false);
    expect(chats.claim('new')).toBe(true);
  });

  it('finds the chat of a tool turn', () => {
    expect(chatOfTurn('abc:lz3:4')).toBe('abc');
    expect(chatOfTurn(undefined)).toBeUndefined();
  });

  it('strips every network tool from the request at the seam', async () => {
    offlineChats.mark('offline-1');
    expect(isOfflineChat('offline-1')).toBe(true);
    clearRequestProviders();
    registerRequestProvider({
      id: 'adds',
      contribute: () => ({
        tools: [tool('read_url'), tool('calculator'), tool('save_memory')],
      }),
    });
    const params = {
      messages: [{role: 'user', content: 'Hello'}],
      tools: [tool('web_search')],
    } as unknown as ApiCompletionParams;
    const allowed = ['web_search', 'render_html'];
    await applyRequestSeam(params, allowed);
    expect(
      ((params.tools ?? []) as ToolDefinition[]).map(
        item => item.function.name,
      ),
    ).toEqual(['calculator']);
    expect(allowed).toEqual(['render_html', 'calculator']);
    expect(getLastSentRequest()?.sessionId).toBe('offline-1');
    clearRequestProviders();
  });

  it('applies the expert temperature to every request', async () => {
    registerRequestProvider({
      id: 'p',
      contribute: () => ({params: {temperature: 0.9}}),
    });
    setSeamEnvironment({sampling: () => ({temperature: 0.2})});
    const params = {
      messages: [{role: 'user', content: 'Hello'}],
    } as unknown as ApiCompletionParams;
    await applyRequestSeam(params, []);
    expect(params.temperature).toBe(0.2);
    setSeamEnvironment({sampling: () => ({})});
    await applyRequestSeam(params, []);
    expect(params.temperature).toBe(0.9);
    clearRequestProviders();
  });
});

describe('"Use my location"', () => {
  afterEach(() => setLocationAllowed(true));

  it('answers without asking the system when location is off', async () => {
    const locate = jest.fn();
    const location = createLocationTool({provider: {locate}});
    setLocationAllowed(false);
    const result = await location.execute({}, {now: new Date()});
    expect(result.text).toBe(LOCATION_OFF_TEXT);
    expect(locate).not.toHaveBeenCalled();
  });
});
