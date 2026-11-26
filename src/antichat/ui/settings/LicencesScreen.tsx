import React, {useMemo, useState} from 'react';
import {FlatList, Linking, ScrollView, View} from 'react-native';
import type {StackScreenProps} from '@react-navigation/stack';
import {StyleSheet} from 'react-native-unistyles';

import {ScreenHeader} from '../../app/screens/ScreenHeader';
import {useT} from '../../locales';
import {Icon, PressableScale, Text, TextField} from '../primitives';
import {
  findLicencePackage,
  licencePackages,
  licenceText,
  packageKey,
  searchPackages,
  type LicencePackage,
} from './about/packages';
import {Group, Row, SettingsPage} from './components';
import {useOpen} from './navigation';
import type {SettingsRoutes} from './routes';

/** Every open-source package in the app, searchable. */
export function LicencesScreen() {
  const t = useT();
  const open = useOpen();
  const [query, setQuery] = useState('');
  const all = useMemo(() => licencePackages(), []);
  const shown = useMemo(() => searchPackages(all, query), [all, query]);
  return (
    <View testID="settings-licences-page" style={styles.screen}>
      <ScreenHeader title={t('settings.about_.licences')} />
      <FlatList
        data={shown}
        keyExtractor={packageKey}
        keyboardShouldPersistTaps="handled"
        keyboardDismissMode="on-drag"
        initialNumToRender={20}
        contentContainerStyle={styles.list}
        ListHeaderComponent={
          <View style={styles.search}>
            <TextField
              testID="licences-search"
              shape="pill"
              icon="search"
              clearable
              value={query}
              onChangeText={setQuery}
              placeholder={t('settings.about_.search')}
              autoCapitalize="none"
              autoCorrect={false}
            />
            <Text variant="footnote" color="textSecondary" style={styles.count}>
              {shown.length === 1
                ? t('settings.about_.licencesCountOne')
                : t('settings.about_.licencesCount', {count: shown.length})}
            </Text>
          </View>
        }
        renderItem={({item}) => (
          <PackageRow
            item={item}
            onPress={() => open('SettingsLicence', {name: packageKey(item)})}
          />
        )}
      />
    </View>
  );
}

function PackageRow({
  item,
  onPress,
}: {
  item: LicencePackage;
  onPress: () => void;
}) {
  return (
    <PressableScale
      accessibilityRole="button"
      accessibilityLabel={`${item.name}, ${item.licence}`}
      scale={false}
      onPress={onPress}
      style={styles.row}>
      <View style={styles.texts}>
        <Text numberOfLines={1}>{item.name}</Text>
        <Text variant="footnote" color="textSecondary" numberOfLines={1}>
          {item.version} · {item.licence}
        </Text>
      </View>
      <Icon name="chevronForward" size={18} color="textTertiary" />
    </PressableScale>
  );
}

/** One package: where it lives and its licence text. */
export function LicenceScreen({
  route,
}: StackScreenProps<SettingsRoutes, 'SettingsLicence'>) {
  const t = useT();
  const item = findLicencePackage(route.params.name);
  const text = item ? licenceText(item) : '';
  if (!item) {
    return (
      <SettingsPage title={t('settings.about_.licences')}>{null}</SettingsPage>
    );
  }
  return (
    <View testID="settings-licence-page" style={styles.screen}>
      <ScreenHeader title={item.name} />
      <ScrollView contentContainerStyle={styles.detail}>
        <Group>
          <Row title={t('settings.about_.version')} value={item.version} />
          <Row title={t('models.detailsSheet.licence')} value={item.licence} />
          {item.url ? (
            <Row
              title={t('settings.about_.homepage')}
              trailing={<Icon name="external" size={16} color="textTertiary" />}
              onPress={() => {
                Linking.openURL(item.url as string).catch(() => {});
              }}
            />
          ) : null}
        </Group>
        <Text variant="footnote" color="textSecondary" selectable>
          {text || t('settings.about_.noLicenceText')}
        </Text>
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create((theme, rt) => ({
  screen: {
    flex: 1,
    backgroundColor: theme.colors.background,
  },
  list: {
    paddingBottom: rt.insets.bottom + theme.spacing.xxl,
  },
  search: {
    gap: theme.spacing.md,
    paddingHorizontal: theme.spacing.lg,
    paddingTop: theme.spacing.sm,
    paddingBottom: theme.spacing.sm,
  },
  count: {
    paddingHorizontal: theme.spacing.lg,
  },
  row: {
    minHeight: 56,
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.md,
    paddingHorizontal: theme.spacing.xxl + theme.spacing.xs,
    paddingVertical: theme.spacing.sm,
  },
  texts: {
    flex: 1,
    gap: theme.spacing.xxs,
  },
  detail: {
    gap: theme.spacing.xl,
    paddingHorizontal: theme.spacing.lg,
    paddingTop: theme.spacing.sm,
    paddingBottom: rt.insets.bottom + theme.spacing.xxl,
  },
}));
