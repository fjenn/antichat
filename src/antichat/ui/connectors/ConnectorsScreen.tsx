import React, {
  memo,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import {devToolsEnabled} from '../../app/flags';
import {FlatList, Platform, ScrollView, View} from 'react-native';
import {observer} from 'mobx-react';
import {StyleSheet} from 'react-native-unistyles';

import {ScreenHeader} from '../../app/screens/ScreenHeader';
import type {Toolkit} from '../../engine/mcp/relay';
import type {ConnectorsStore, CustomServer} from '../../engine/mcp/store';
import {
  Button,
  Chip,
  Icon,
  InlineError,
  ListRow,
  PressableScale,
  Sheet,
  Skeleton,
  Text,
  TextField,
  toast,
  type SheetHandle,
} from '../primitives';
import {AppLogo} from './AppLogo';
import {ConnectAppCard} from './ConnectAppCard';
import {buildDirectory, type DirectoryRow} from './directory';
import {useConnectors} from './session';
import {s} from './strings';

type Selection =
  | {kind: 'app'; slug: string}
  | {kind: 'server'; id: string}
  | {kind: 'add'}
  | null;

/** Settings › Connectors. */
export function ConnectorsScreen() {
  return <ConnectorsView store={useConnectors()} />;
}

export const ConnectorsView = observer(function Connectors({
  store,
}: {
  store: ConnectorsStore;
}) {
  const [query, setQuery] = useState('');
  const [selection, setSelection] = useState<Selection>(null);
  const sheet = useRef<SheetHandle>(null);
  const online = store.online;

  useEffect(() => {
    if (online) {
      store.refresh().catch(() => {});
    } else {
      store.load().catch(() => {});
    }
  }, [online, store]);

  const open = (next: Selection) => {
    store.clearError();
    setSelection(next);
    sheet.current?.present().catch(() => {});
  };
  const close = () => {
    sheet.current?.dismiss().catch(() => {});
  };

  const toolkits = store.toolkits;
  const searching = query.trim().length > 0;
  const [group, setGroup] = useState<string | null>(null);
  // Categories start collapsed; Popular and Connected sit above them, open.
  const [expanded, setExpanded] = useState<ReadonlySet<string>>(
    () => new Set(),
  );
  const toggleGroup = useCallback(
    (id: string) =>
      setExpanded(current => {
        const next = new Set(current);
        if (!next.delete(id)) {
          next.add(id);
        }
        return next;
      }),
    [],
  );
  // Browsing: Popular, then every app under its category. A search covers
  // the whole directory by name, slug and category.
  const directory = useMemo(
    () => buildDirectory(toolkits, group, expanded),
    [toolkits, group, expanded],
  );
  const rows: DirectoryRow[] = useMemo(
    () =>
      searching
        ? store.search(query).map(toolkit => ({
            kind: 'app' as const,
            key: toolkit.slug,
            toolkit,
          }))
        : directory.rows,
    // `toolkits` is the observable the search runs over.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [query, searching, toolkits, store, directory],
  );
  const connected = store.connectedSlugs;
  const loading = store.toolkitsState === 'loading' && toolkits.length === 0;

  const openApp = useCallback(
    (slug: string) => open({kind: 'app', slug}),
    // `open` only touches refs and state setters.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [],
  );
  const renderRow = ({item}: {item: DirectoryRow}) =>
    item.kind === 'header' ? (
      <GroupHeader
        id={item.id}
        title={item.title}
        count={item.count}
        expanded={item.expanded}
        onToggle={toggleGroup}
      />
    ) : (
      <DirectoryAppRow
        toolkit={item.toolkit}
        online={online}
        connected={connected.includes(item.toolkit.slug)}
        onOpen={openApp}
      />
    );

  const header = (
    <View style={styles.header}>
      {online ? null : (
        <Text
          testID="connectors-offline"
          variant="footnote"
          color="textTertiary"
          style={styles.sectionTitle}>
          {s.offline}
        </Text>
      )}
      <TextField
        testID="connectors-search"
        shape="pill"
        icon="search"
        clearable
        placeholder={s.searchPlaceholder}
        value={query}
        onChangeText={setQuery}
        autoCorrect={false}
        autoCapitalize="none"
        returnKeyType="search"
        editable={online}
      />
      {searching ? null : (
        <View style={styles.addRow}>
          <ListRow
            testID="add-server"
            icon="add"
            title={s.addServer}
            subtitle={s.addServerHint}
            chevron
            disabled={!online}
            onPress={() => open({kind: 'add'})}
          />
        </View>
      )}
      {store.error && !selection ? (
        <InlineError
          testID="connectors-error"
          message={store.error}
          onRetry={() => store.refresh().catch(() => {})}
        />
      ) : null}

      {searching ? null : (
        <>
          {connected.length + store.servers.length > 0 ? (
            <View>
              <SectionTitle title={s.connected} />
              {connected.map(slug => {
                const toolkit = toolkits.find(item => item.slug === slug);
                return (
                  <AppRow
                    key={slug}
                    testID={`connected-${slug}`}
                    name={store.title(slug)}
                    logo={online ? toolkit?.logo : undefined}
                    connected
                    disabled={!online}
                    onPress={() => open({kind: 'app', slug})}
                  />
                );
              })}
              {store.servers.map(server => (
                <AppRow
                  key={server.id}
                  testID={`server-${server.id}`}
                  name={server.name}
                  description={serverLine(server)}
                  connected={server.state === 'connected'}
                  warning={server.state !== 'connected'}
                  disabled={!online}
                  onPress={() => open({kind: 'server', id: server.id})}
                />
              ))}
            </View>
          ) : null}
          {devToolsEnabled() ? (
            <View>
              <ListRow
                testID="preview-card"
                icon="info"
                title={s.previewCard}
                onPress={() => store.showCard('Gmail')}
              />
              <ListRow
                testID="preview-approval"
                icon="info"
                title={s.previewApproval}
                onPress={() => {
                  store.permissions
                    .allow({
                      key: 'preview:GMAIL_SEND_EMAIL',
                      app: 'Gmail',
                      action: 'Send email',
                      arguments: {
                        recipient_email: 'someone@example.com',
                        subject: 'Hello',
                        body: 'This is a preview. Nothing is sent.',
                      },
                      write: true,
                    })
                    .then(allowed => {
                      store.permissions
                        .setPolicy('preview:GMAIL_SEND_EMAIL', null)
                        .catch(() => {});
                      toast.show({
                        message: allowed ? 'Allowed' : 'Not allowed',
                      });
                    })
                    .catch(() => {});
                }}
              />
            </View>
          ) : null}
        </>
      )}
      {searching || directory.popular.length === 0 ? null : (
        <View>
          <SectionTitle title={s.popular} />
          <ScrollView
            testID="connectors-popular"
            horizontal
            showsHorizontalScrollIndicator={false}
            contentContainerStyle={styles.popular}
            style={styles.bleed}>
            {directory.popular.map(toolkit => (
              <PopularTile
                key={toolkit.slug}
                toolkit={toolkit}
                logo={online ? toolkit.logo : undefined}
                connected={connected.includes(toolkit.slug)}
                disabled={!online}
                onPress={() => open({kind: 'app', slug: toolkit.slug})}
              />
            ))}
          </ScrollView>
        </View>
      )}
      {searching || directory.groups.length === 0 ? (
        <SectionTitle title={searching ? s.results : s.apps} />
      ) : (
        <ScrollView
          testID="connectors-groups"
          horizontal
          showsHorizontalScrollIndicator={false}
          keyboardShouldPersistTaps="handled"
          contentContainerStyle={styles.chips}
          style={styles.bleed}>
          <Chip
            testID="group-all"
            label={s.allApps(toolkits.length)}
            selected={group === null}
            onPress={() => setGroup(null)}
          />
          {directory.groups.map(item => (
            <Chip
              key={item.id}
              testID={`group-${item.id}`}
              label={item.title}
              selected={group === item.id}
              onPress={() =>
                setGroup(current => (current === item.id ? null : item.id))
              }
            />
          ))}
        </ScrollView>
      )}
      {loading ? (
        <View testID="connectors-loading" style={styles.loading}>
          {[0, 1, 2, 3, 4, 5].map(row => (
            <Skeleton key={row} height={44} radius={12} />
          ))}
        </View>
      ) : null}
    </View>
  );

  return (
    <View testID="connectors" style={styles.screen}>
      <ScreenHeader title={s.title} />
      <FlatList
        testID="connectors-list"
        data={rows}
        keyExtractor={item => item.key}
        keyboardShouldPersistTaps="handled"
        keyboardDismissMode="on-drag"
        initialNumToRender={14}
        maxToRenderPerBatch={12}
        windowSize={9}
        removeClippedSubviews={Platform.OS === 'android'}
        contentContainerStyle={styles.content}
        ListHeaderComponent={header}
        ListEmptyComponent={
          loading || store.toolkitsState === 'idle' ? undefined : (
            <Text
              testID="connectors-empty"
              variant="callout"
              color="textSecondary"
              align="center"
              style={styles.empty}>
              {toolkits.length === 0 && store.toolkitsState === 'error'
                ? s.loadFailed
                : s.noResults}
            </Text>
          )
        }
        renderItem={renderRow}
      />
      <Sheet
        ref={sheet}
        testID="connectors-sheet"
        onDismiss={() => setSelection(null)}>
        {selection?.kind === 'app' ? (
          <AppDetail store={store} slug={selection.slug} onDone={close} />
        ) : selection?.kind === 'server' ? (
          <ServerDetail store={store} id={selection.id} onDone={close} />
        ) : selection?.kind === 'add' ? (
          <AddServer store={store} onDone={close} />
        ) : null}
      </Sheet>
    </View>
  );
});

function serverLine(server: CustomServer): string {
  return server.state === 'connected'
    ? s.serverTools(server.tools.length)
    : server.state === 'needs_signin'
      ? s.serverNeedsSignIn
      : s.serverError;
}

function SectionTitle({title}: {title: string}) {
  return (
    <Text
      variant="footnote"
      color="textSecondary"
      accessibilityRole="header"
      style={styles.sectionTitle}>
      {title}
    </Text>
  );
}

const GroupHeader = memo(function Group({
  id,
  title,
  count,
  expanded,
  onToggle,
}: {
  id: string;
  title: string;
  count: number;
  expanded: boolean;
  onToggle: (id: string) => void;
}) {
  return (
    <PressableScale
      testID={`group-header-${id}`}
      accessibilityRole="button"
      accessibilityLabel={`${title}, ${s.appCount(count)}`}
      accessibilityState={{expanded}}
      scale={false}
      onPress={() => onToggle(id)}>
      <View style={styles.groupHeader}>
        <Text variant="calloutStrong" style={styles.groupTitle}>
          {title}
        </Text>
        <Text variant="footnote" color="textTertiary">
          {count}
        </Text>
        <Icon
          name={expanded ? 'chevronDown' : 'chevronForward'}
          size={18}
          color="textTertiary"
        />
      </View>
    </PressableScale>
  );
});

const DirectoryAppRow = memo(function DirectoryApp({
  toolkit,
  online,
  connected,
  onOpen,
}: {
  toolkit: Toolkit;
  online: boolean;
  connected: boolean;
  onOpen: (slug: string) => void;
}) {
  return (
    <AppRow
      testID={`app-${toolkit.slug}`}
      name={toolkit.name}
      description={toolkit.description}
      logo={online ? toolkit.logo : undefined}
      connected={connected}
      disabled={!online}
      onPress={() => onOpen(toolkit.slug)}
    />
  );
});

function PopularTile({
  toolkit,
  logo,
  connected,
  disabled,
  onPress,
}: {
  toolkit: Toolkit;
  logo?: string;
  connected: boolean;
  disabled: boolean;
  onPress: () => void;
}) {
  return (
    <PressableScale
      testID={`popular-${toolkit.slug}`}
      accessibilityRole="button"
      accessibilityLabel={[toolkit.name, connected ? s.connected : '']
        .filter(Boolean)
        .join(', ')}
      accessibilityState={{disabled}}
      disabled={disabled}
      onPress={onPress}>
      <View style={styles.tile(disabled)}>
        <View>
          <AppLogo name={toolkit.name} uri={logo} size={56} />
          {connected ? (
            <View style={styles.tileBadge}>
              <Icon name="check" size={12} color="onAccent" />
            </View>
          ) : null}
        </View>
        <Text
          variant="caption"
          color="textSecondary"
          align="center"
          numberOfLines={2}>
          {toolkit.name}
        </Text>
      </View>
    </PressableScale>
  );
}

function AppRow({
  name,
  description,
  logo,
  connected = false,
  warning = false,
  disabled = false,
  onPress,
  testID,
}: {
  name: string;
  description?: string;
  logo?: string;
  connected?: boolean;
  warning?: boolean;
  disabled?: boolean;
  onPress: () => void;
  testID?: string;
}) {
  return (
    <PressableScale
      testID={testID}
      accessibilityRole="button"
      accessibilityLabel={[name, connected ? s.connected : '', description]
        .filter(Boolean)
        .join(', ')}
      accessibilityState={{disabled}}
      disabled={disabled}
      scale={false}
      onPress={onPress}>
      <View style={styles.appRow(disabled)}>
        <AppLogo name={name} uri={logo} />
        <View style={styles.texts}>
          <Text variant="body" numberOfLines={1}>
            {name}
          </Text>
          {description ? (
            <Text variant="footnote" color="textSecondary" numberOfLines={1}>
              {description}
            </Text>
          ) : null}
        </View>
        {warning ? (
          <Icon name="alert" size={18} color="warning" />
        ) : connected ? (
          <Icon name="check" size={18} color="success" />
        ) : (
          <Icon name="chevronForward" size={18} color="textTertiary" />
        )}
      </View>
    </PressableScale>
  );
}

const AppDetail = observer(function Detail({
  store,
  slug,
  onDone,
}: {
  store: ConnectorsStore;
  slug: string;
  onDone: () => void;
}) {
  const toolkit = store.toolkits.find(item => item.slug === slug);
  const name = toolkit?.name ?? store.title(slug);
  const connected = store.isConnected(slug);
  const [busy, setBusy] = useState(false);
  return (
    <View testID="app-detail" style={styles.detail}>
      <ConnectAppCard store={store} slug={slug} name={name} plain />
      {toolkit?.description ? (
        <Text variant="callout" color="textSecondary">
          {toolkit.description}
        </Text>
      ) : null}
      <Text variant="footnote" color="textTertiary">
        {connected ? s.connectedNote(name) : s.signInNote}
      </Text>
      {connected ? (
        <Button
          testID="app-disconnect"
          label={s.disconnect}
          variant="destructive"
          fullWidth
          loading={busy}
          disabled={!store.online}
          onPress={async () => {
            setBusy(true);
            await store.disconnect(slug);
            setBusy(false);
            if (!store.isConnected(slug)) {
              toast.show({message: s.disconnectedToast(name)});
              onDone();
            }
          }}
        />
      ) : null}
    </View>
  );
});

const ServerDetail = observer(function Detail({
  store,
  id,
  onDone,
}: {
  store: ConnectorsStore;
  id: string;
  onDone: () => void;
}) {
  const server = store.servers.find(item => item.id === id);
  const [busy, setBusy] = useState(false);
  if (!server) {
    return null;
  }
  return (
    <View testID="server-detail" style={styles.detail}>
      <View style={styles.detailHead}>
        <AppLogo name={server.name} size={44} />
        <View style={styles.texts}>
          <Text variant="headline" numberOfLines={1}>
            {server.name}
          </Text>
          <Text variant="footnote" color="textSecondary" numberOfLines={2}>
            {server.url}
          </Text>
        </View>
      </View>
      <Text variant="callout" color="textSecondary">
        {serverLine(server)}
        {server.state === 'connected' && server.tools.length
          ? `: ${server.tools
              .slice(0, 6)
              .map(tool => tool.name)
              .join(', ')}${server.tools.length > 6 ? '…' : ''}`
          : ''}
      </Text>
      {store.error ? (
        <Text variant="footnote" color="danger" accessibilityRole="alert">
          {store.error}
        </Text>
      ) : null}
      {server.state !== 'connected' ? (
        <Button
          testID="server-signin"
          label={s.signInAgain}
          fullWidth
          loading={busy}
          disabled={!store.online}
          onPress={async () => {
            setBusy(true);
            await store.addServer(server.url);
            setBusy(false);
          }}
        />
      ) : null}
      <Button
        testID="server-remove"
        label={s.remove}
        variant="destructive"
        fullWidth
        onPress={async () => {
          await store.removeServer(server.id);
          onDone();
        }}
      />
    </View>
  );
});

const AddServer = observer(function Add({
  store,
  onDone,
}: {
  store: ConnectorsStore;
  onDone: () => void;
}) {
  const [url, setUrl] = useState('');
  const [busy, setBusy] = useState(false);
  const add = async () => {
    setBusy(true);
    const server = await store.addServer(url);
    setBusy(false);
    if (server) {
      toast.show({message: s.serverAdded(server.name), kind: 'success'});
      onDone();
    }
  };
  return (
    <View testID="add-server-sheet" style={styles.detail}>
      <Text variant="headline" align="center" accessibilityRole="header">
        {s.addServer}
      </Text>
      <TextField
        testID="server-url"
        label={s.serverUrl}
        placeholder={s.serverUrlPlaceholder}
        value={url}
        onChangeText={setUrl}
        error={store.error ?? undefined}
        autoCapitalize="none"
        autoCorrect={false}
        keyboardType="url"
        returnKeyType="done"
        onSubmitEditing={add}
      />
      <Text variant="footnote" color="textTertiary">
        {s.signInNote}
      </Text>
      <Button
        testID="server-add"
        label={s.add}
        fullWidth
        loading={busy}
        disabled={!url.trim() || !store.online}
        onPress={add}
      />
    </View>
  );
});

const styles = StyleSheet.create((theme, rt) => ({
  screen: {
    flex: 1,
    backgroundColor: theme.colors.background,
  },
  content: {
    paddingHorizontal: theme.spacing.lg,
    paddingBottom: rt.insets.bottom + theme.spacing.xxl,
  },
  header: {
    gap: theme.spacing.lg,
    paddingTop: theme.spacing.sm,
  },
  addRow: {
    marginHorizontal: -theme.spacing.sm,
    marginVertical: -theme.spacing.sm,
  },
  bleed: {
    marginHorizontal: -theme.spacing.lg,
  },
  popular: {
    paddingHorizontal: theme.spacing.lg,
    gap: theme.spacing.md,
  },
  chips: {
    paddingHorizontal: theme.spacing.lg,
    gap: theme.spacing.sm,
  },
  groupHeader: {
    minHeight: 48,
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.sm,
    paddingHorizontal: theme.spacing.xs,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: theme.colors.border,
  },
  groupTitle: {
    flex: 1,
  },
  tile: (disabled: boolean) => ({
    width: 72,
    alignItems: 'center',
    gap: theme.spacing.xs,
    opacity: disabled ? 0.45 : 1,
  }),
  tileBadge: {
    position: 'absolute',
    right: -4,
    bottom: -4,
    width: 20,
    height: 20,
    borderRadius: 10,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: theme.colors.success,
    borderWidth: 2,
    borderColor: theme.colors.background,
  },
  sectionTitle: {
    paddingHorizontal: theme.spacing.xs,
    paddingBottom: theme.spacing.xs,
  },
  loading: {
    gap: theme.spacing.md,
  },
  empty: {
    paddingVertical: theme.spacing.xxxl,
  },
  appRow: (disabled: boolean) => ({
    minHeight: 60,
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.md,
    paddingVertical: theme.spacing.sm,
    paddingHorizontal: theme.spacing.xs,
    opacity: disabled ? 0.45 : 1,
  }),
  texts: {
    flex: 1,
    gap: theme.spacing.xxs,
  },
  detail: {
    gap: theme.spacing.lg,
  },
  detailHead: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.md,
  },
}));
