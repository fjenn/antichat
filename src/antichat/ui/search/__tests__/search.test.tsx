import '../../../testing/setup';

import AsyncStorage from '@react-native-async-storage/async-storage';
import React from 'react';
import {act, fireEvent, render, screen} from '@testing-library/react-native';

import type {ConversationView, SearchHit} from '../../../contracts';
import {FakeConversations} from '../../../contracts/fakes';
import {shortDate} from '../dates';
import {splitRuns} from '../Highlighted';
import {
  MAX_RECENT_SEARCHES,
  recentSearches,
  withRecent,
} from '../recentSearches';
import {SearchPanel} from '../SearchPanel';
import {SEARCH_DEBOUNCE_MS} from '../useChatSearch';

const NOW = new Date(2026, 10, 24, 15, 0, 0).getTime();
const DAY = 24 * 60 * 60 * 1000;

describe('highlight runs', () => {
  it('splits text at the marked ranges', () => {
    expect(
      splitRuns('split it into mornings', [
        [14, 22],
        [0, 5],
      ]),
    ).toEqual([
      {text: 'split', match: true},
      {text: ' it into ', match: false},
      {text: 'mornings', match: true},
    ]);
  });

  it('survives overlapping, empty and out-of-range ranges', () => {
    expect(
      splitRuns('abcdef', [
        [1, 3],
        [2, 4],
        [5, 5],
        [4, 99],
        [-3, 1],
      ]),
    ).toEqual([
      {text: 'a', match: true},
      {text: 'bc', match: true},
      {text: 'd', match: true},
      {text: 'ef', match: true},
    ]);
    expect(splitRuns('plain')).toEqual([{text: 'plain', match: false}]);
    expect(splitRuns('')).toEqual([]);
  });
});

describe('recent searches', () => {
  beforeEach(() => recentSearches.reset());

  it('keeps the newest first, without duplicates, capped', () => {
    let list: readonly string[] = [];
    for (let i = 0; i < MAX_RECENT_SEARCHES + 3; i++) {
      list = withRecent(list, `query ${i}`);
    }
    expect(list).toHaveLength(MAX_RECENT_SEARCHES);
    expect(list[0]).toBe(`query ${MAX_RECENT_SEARCHES + 2}`);
    expect(withRecent(list, '  QUERY   5 ')[0]).toBe('QUERY 5');
    expect(withRecent(list, 'QUERY 5')).toHaveLength(MAX_RECENT_SEARCHES);
    expect(withRecent(list, '   ')).toBe(list);
  });

  it('remembers across a reload', async () => {
    recentSearches.add('tides');
    recentSearches.add('lisbon');
    recentSearches.remove('tides');
    await Promise.resolve();
    recentSearches.reset();
    expect(recentSearches.list()).toEqual([]);
    await recentSearches.load();
    expect(recentSearches.list()).toEqual(['lisbon']);
    recentSearches.clear();
    expect(recentSearches.list()).toEqual([]);
  });
});

describe('short dates', () => {
  const labels = {today: 'Today', yesterday: 'Yesterday'};
  it('names today and yesterday and dates the rest', () => {
    expect(shortDate(NOW - 60_000, NOW, labels)).toBe('Today');
    expect(shortDate(NOW - 20 * 60 * 60 * 1000, NOW, labels)).toBe('Yesterday');
    const thisYear = shortDate(NOW - 30 * DAY, NOW, labels);
    expect(thisYear).toMatch(/25/);
    expect(thisYear).not.toMatch(/2026/);
    expect(shortDate(NOW - 400 * DAY, NOW, labels)).toMatch(/2025/);
  });
});

describe('SearchPanel', () => {
  const conversation: ConversationView = {
    id: 'c1',
    title: 'Weekend plans',
    updatedAt: NOW - 3 * DAY,
    createdAt: NOW - 3 * DAY,
    pinned: false,
    archived: false,
    temporary: false,
    locked: false,
  };

  class Port extends FakeConversations {
    calls: string[] = [];
    answers = new Map<string, SearchHit[]>();
    async search(query: string): Promise<SearchHit[]> {
      this.calls.push(query);
      return this.answers.get(query) ?? [];
    }
  }

  beforeEach(async () => {
    await AsyncStorage.clear();
    jest.useFakeTimers();
    recentSearches.reset();
  });
  afterEach(() => jest.useRealTimers());

  const settle = async () => {
    await act(async () => {
      jest.advanceTimersByTime(SEARCH_DEBOUNCE_MS + 10);
      await Promise.resolve();
      await Promise.resolve();
    });
  };

  it('shows a hint, then recent searches, under an empty field', async () => {
    const port = new Port({empty: true});
    const onPick = jest.fn();
    render(
      <SearchPanel
        port={port}
        query=""
        onOpen={jest.fn()}
        onPickRecent={onPick}
      />,
    );
    expect(screen.getByTestId('search-empty')).toBeTruthy();
    act(() => recentSearches.add('mornings'));
    expect(screen.getByTestId('search-recent')).toBeTruthy();
    fireEvent.press(screen.getByTestId('search-recent-0'));
    expect(onPick).toHaveBeenCalledWith('mornings');
    fireEvent.press(screen.getByTestId('search-recent-clear'));
    expect(screen.getByTestId('search-empty')).toBeTruthy();
  });

  it('searches once typing pauses and shows title, snippet and date', async () => {
    const port = new Port({empty: true});
    port.answers.set('morn', [
      {
        conversation,
        messageId: 'm7',
        snippet: '…split it into mornings and evenings',
        matches: [[15, 23]],
        titleMatches: [],
      },
    ]);
    const onOpen = jest.fn();
    const view = render(
      <SearchPanel
        port={port}
        query="m"
        now={NOW}
        onOpen={onOpen}
        onPickRecent={jest.fn()}
      />,
    );
    // Typing on: only the query the user stopped on is searched.
    view.rerender(
      <SearchPanel
        port={port}
        query="morn"
        now={NOW}
        onOpen={onOpen}
        onPickRecent={jest.fn()}
      />,
    );
    await settle();
    expect(port.calls).toEqual(['morn']);
    expect(screen.getByText('Weekend plans')).toBeTruthy();
    expect(screen.getByText('mornings').props.style).toEqual(
      expect.arrayContaining([expect.objectContaining({fontWeight: '700'})]),
    );
    fireEvent.press(screen.getByTestId('search-hit-c1'));
    expect(onOpen).toHaveBeenCalledWith(
      expect.objectContaining({messageId: 'm7'}),
      'morn',
    );
  });

  it('says so when nothing matches, and hides chats being deleted', async () => {
    const port = new Port({empty: true});
    port.answers.set('plans', [{conversation, matches: [[8, 13]]}]);
    const view = render(
      <SearchPanel
        port={port}
        query="zzz"
        onOpen={jest.fn()}
        onPickRecent={jest.fn()}
      />,
    );
    expect(screen.queryByTestId('search-no-results')).toBeNull();
    await settle();
    expect(screen.getByTestId('search-no-results')).toBeTruthy();

    view.rerender(
      <SearchPanel
        port={port}
        query="plans"
        hidden={new Set(['c1'])}
        onOpen={jest.fn()}
        onPickRecent={jest.fn()}
      />,
    );
    await settle();
    expect(screen.queryByTestId('search-hit-c1')).toBeNull();
  });

  it('drops the answer to a query the user has typed past', async () => {
    const port = new Port({empty: true});
    let release: (hits: SearchHit[]) => void = () => {};
    port.search = jest.fn(
      (query: string) =>
        new Promise<SearchHit[]>(resolve => {
          if (query === 'slow') {
            release = resolve;
          } else {
            resolve([]);
          }
        }),
    );
    const props = {port, onOpen: jest.fn(), onPickRecent: jest.fn()};
    const view = render(<SearchPanel {...props} query="slow" />);
    await settle();
    view.rerender(<SearchPanel {...props} query="fast" />);
    await settle();
    await act(async () => {
      release([{conversation, matches: []}]);
      await Promise.resolve();
    });
    expect(screen.queryByTestId('search-hit-c1')).toBeNull();
    expect(screen.getByTestId('search-no-results')).toBeTruthy();
  });
});
