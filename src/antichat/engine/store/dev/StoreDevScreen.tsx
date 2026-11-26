/**
 * Developer screen for the conversation store. "Run all" exercises every
 * operation against the real databases and prints PASS / FAIL per check;
 * the same report is written to `Documents/antichat-store-dev.json`.
 * The buttons below it poke single operations by hand.
 *
 * Not reachable in the shipped app; a dev menu (M1) or a temporary root
 * swap mounts it. Chats it creates are titled "[dev] …" and deleted by the
 * last check.
 */
import React, {useCallback, useEffect, useRef, useState} from 'react';
import {
  Pressable,
  SafeAreaView,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';

import {chatSessionStore} from '../../../../store/ChatSessionStore';
import {conversationAdapter} from '../../../adapters/conversation';
import {runStoreChecks, searchLatency} from './checks';

let autoRan = false;

export const StoreDevScreen = ({autoRun = true}: {autoRun?: boolean}) => {
  const [lines, setLines] = useState<string[]>(['Conversation store checks']);
  const [running, setRunning] = useState(false);
  const [query, setQuery] = useState('');
  const scroll = useRef<React.ElementRef<typeof ScrollView>>(null);

  const log = useCallback((line: string) => {
    setLines(previous => [...previous.slice(-400), line]);
  }, []);

  const guarded = useCallback(
    (label: string, work: () => Promise<string>) => async () => {
      if (running) {
        return;
      }
      setRunning(true);
      try {
        log(`${label}: ${await work()}`);
      } catch (error: any) {
        log(`${label} failed: ${String(error?.message ?? error)}`);
      } finally {
        setRunning(false);
      }
    },
    [log, running],
  );

  const runAll = useCallback(async () => {
    setRunning(true);
    try {
      await runStoreChecks(log);
    } catch (error: any) {
      log(`aborted: ${String(error?.message ?? error)}`);
    } finally {
      setRunning(false);
    }
  }, [log]);

  useEffect(() => {
    if (autoRun && !autoRan) {
      autoRan = true; // fast refresh must not start a second run
      runAll();
    }
  }, [autoRun, runAll]);

  const port = conversationAdapter();
  const active = () => {
    const id = chatSessionStore.activeSessionId;
    if (!id) {
      throw new Error('open a chat first (Run all leaves none open)');
    }
    return id;
  };

  const actions: [string, () => Promise<string>][] = [
    ['Stats', async () => JSON.stringify(await (await port.store()).stats())],
    [
      'History',
      async () => {
        const listing = await port.listHistory({scope: 'all'});
        return [
          `pinned ${listing.pinned.length}`,
          ...listing.groups.map(g => `${g.label} ${g.items.length}`),
        ].join(', ');
      },
    ],
    [
      'Search',
      async () => {
        const start = performance.now();
        const hits = await port.search(query, {includeArchived: true});
        const ms = (performance.now() - start).toFixed(1);
        return (
          `${hits.length} chats in ${ms} ms` +
          hits
            .slice(0, 5)
            .map(
              hit =>
                `\n  ${hit.title}: ${(
                  hit.snippet?.segments ?? hit.titleSegments
                )
                  .map(s => (s.match ? `[${s.text}]` : s.text))
                  .join('')}`,
            )
            .join('')
        );
      },
    ],
    ['Latency 5k', searchLatency],
    [
      'Sync all',
      async () => {
        await (await port.store()).syncAll();
        return 'done';
      },
    ],
    [
      'Thread',
      async () =>
        (await port.getThread(active()))
          .map(
            m =>
              `\n  ${m.role} ${m.versionIndex + 1}/${m.versionCount} ${m.text.slice(0, 40)}`,
          )
          .join(''),
    ],
    [
      'Archive',
      async () => {
        const id = active();
        const meta = await port.getMeta(id);
        await port.setArchived(id, !meta?.archivedAt);
        return meta?.archivedAt ? 'unarchived' : 'archived';
      },
    ],
    [
      'Pin',
      async () => {
        const id = active();
        const meta = await port.getMeta(id);
        await port.setPinned(id, !meta?.pinnedAt);
        return meta?.pinnedAt ? 'unpinned' : 'pinned';
      },
    ],
    [
      'Lock',
      async () => {
        const id = active();
        const meta = await port.getMeta(id);
        await port.setLocked(id, !meta?.locked);
        return meta?.locked ? 'unlocked' : 'locked';
      },
    ],
    [
      'Branch at end',
      async () => {
        const thread = await port.getThread(active());
        return port.branch(active(), thread[thread.length - 1].messageId);
      },
    ],
    [
      'Markdown',
      async () => (await port.exportMarkdown(active())).slice(0, 400),
    ],
    ['Export zip', async () => `${(await port.exportArchive()).length} bytes`],
    [
      'Next chat temporary',
      async () => {
        port.startTemporaryChat();
        return 'armed';
      },
    ],
  ];

  return (
    <SafeAreaView style={styles.root}>
      <View style={styles.bar}>
        <Pressable
          style={[styles.button, styles.primary]}
          onPress={runAll}
          disabled={running}
          testID="store-dev-run-all">
          <Text style={styles.buttonText}>
            {running ? 'Running…' : 'Run all'}
          </Text>
        </Pressable>
        <TextInput
          style={styles.input}
          value={query}
          onChangeText={setQuery}
          placeholder="search text"
          placeholderTextColor="#77777d"
          autoCapitalize="none"
          autoCorrect={false}
          testID="store-dev-query"
        />
      </View>
      <View style={styles.actions}>
        {actions.map(([label, work]) => (
          <Pressable
            key={label}
            style={styles.button}
            onPress={guarded(label, work)}
            disabled={running}>
            <Text style={styles.buttonText}>{label}</Text>
          </Pressable>
        ))}
      </View>
      <ScrollView
        ref={scroll}
        contentContainerStyle={styles.content}
        onContentSizeChange={() =>
          scroll.current?.scrollToEnd({animated: false})
        }>
        {lines.map((line, index) => (
          <Text
            key={index}
            style={[
              styles.line,
              line.startsWith('PASS') && styles.pass,
              (line.startsWith('FAIL') || line.includes('failed:')) &&
                styles.fail,
            ]}
            testID={
              index === lines.length - 1 ? 'store-dev-last-line' : undefined
            }>
            {line}
          </Text>
        ))}
      </ScrollView>
    </SafeAreaView>
  );
};

const styles = StyleSheet.create({
  root: {flex: 1, backgroundColor: '#0b0b0c'},
  bar: {flexDirection: 'row', gap: 8, paddingHorizontal: 12, paddingTop: 8},
  actions: {flexDirection: 'row', flexWrap: 'wrap', gap: 6, padding: 12},
  button: {
    backgroundColor: '#26262a',
    borderRadius: 8,
    paddingHorizontal: 10,
    paddingVertical: 7,
  },
  primary: {backgroundColor: '#2f6fed'},
  buttonText: {color: '#f2f2f4', fontSize: 13},
  input: {
    flex: 1,
    backgroundColor: '#1a1a1d',
    borderRadius: 8,
    color: '#f2f2f4',
    paddingHorizontal: 10,
    paddingVertical: 6,
    fontSize: 13,
  },
  content: {padding: 12},
  line: {color: '#d7d7db', fontFamily: 'Menlo', fontSize: 11, marginBottom: 4},
  pass: {color: '#7bd88f'},
  fail: {color: '#ff6b6b'},
});
