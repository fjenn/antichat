import '../../../testing/setup';

import AsyncStorage from '@react-native-async-storage/async-storage';

import {DraftStore} from '../drafts';

jest.useFakeTimers();

describe('drafts', () => {
  beforeEach(async () => {
    await AsyncStorage.clear();
  });

  it('keeps one draft per chat, and one for the new chat', () => {
    const drafts = new DraftStore();
    drafts.set('a', 'for a');
    drafts.set(null, 'for the new chat');
    expect(drafts.get('a')).toBe('for a');
    expect(drafts.get('b')).toBe('');
    expect(drafts.get(null)).toBe('for the new chat');
  });

  it('survives a restart', async () => {
    const first = new DraftStore();
    first.set('a', 'half a thought');
    jest.runAllTimers();
    await Promise.resolve();
    const second = new DraftStore();
    await second.load();
    expect(second.get('a')).toBe('half a thought');
  });

  it('forgets a draft that was sent', async () => {
    const drafts = new DraftStore();
    drafts.set('a', 'text');
    drafts.clear('a');
    jest.runAllTimers();
    await Promise.resolve();
    const next = new DraftStore();
    await next.load();
    expect(next.get('a')).toBe('');
  });

  it('moves the new chat draft to the chat it became', () => {
    const drafts = new DraftStore();
    drafts.set(null, 'first words');
    drafts.move(null, 'c1');
    expect(drafts.get('c1')).toBe('first words');
    expect(drafts.get(null)).toBe('');
  });

  it('does not let stored drafts overwrite what was typed meanwhile', async () => {
    const first = new DraftStore();
    first.set('a', 'old');
    jest.runAllTimers();
    await Promise.resolve();
    const second = new DraftStore();
    second.set('a', 'new');
    await second.load();
    expect(second.get('a')).toBe('new');
  });
});
