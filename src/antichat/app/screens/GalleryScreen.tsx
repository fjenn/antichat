import React, {useRef, useState} from 'react';
import {ScrollView, View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {fakePortNames} from '../../adapters';
import {useT} from '../../locales';
import type {TextVariant} from '../../theme';
import {
  Button,
  Chip,
  ContextMenu,
  GlassSurface,
  IconButton,
  InlineError,
  ListRow,
  Sheet,
  Skeleton,
  Text,
  TextField,
  Toggle,
  toast,
  type SheetHandle,
} from '../../ui/primitives';
import {ScreenHeader} from './ScreenHeader';

const TYPE: TextVariant[] = [
  'largeTitle',
  'title',
  'headline',
  'body',
  'callout',
  'footnote',
  'caption',
];

/**
 * Every primitive on one screen, for the paired light/dark screenshots, the
 * Dynamic Type check and the VoiceOver/TalkBack pass. Debug builds only.
 */
export function GalleryScreen() {
  const t = useT();
  const sheet = useRef<SheetHandle>(null);
  const [toggle, setToggle] = useState(true);
  const [name, setName] = useState('');
  const [chips, setChips] = useState({search: true, think: false, file: true});

  return (
    <View testID="gallery" style={styles.screen}>
      <ScreenHeader title={t('gallery.title')} />
      <ScrollView
        testID="gallery-scroll"
        contentContainerStyle={styles.content}
        keyboardShouldPersistTaps="handled">
        <Section title={t('gallery.buttons')}>
          <Button label={t('gallery.primary')} fullWidth size="lg" />
          <View style={styles.wrap}>
            <Button label={t('gallery.secondary')} variant="secondary" />
            <Button label={t('gallery.ghost')} variant="ghost" />
            <Button
              label={t('gallery.destructive')}
              variant="destructive"
              icon="delete"
            />
            <Button label={t('gallery.busy')} variant="secondary" loading />
            <Button label={t('gallery.primary')} disabled />
          </View>
        </Section>

        <Section title={t('gallery.iconButtons')}>
          <View style={styles.wrap}>
            <IconButton
              icon="menu"
              variant="glass"
              accessibilityLabel={t('shell.openDrawer')}
            />
            <IconButton
              icon="newChat"
              variant="filled"
              accessibilityLabel={t('shell.newChat')}
            />
            <IconButton icon="mic" accessibilityLabel={t('composer.dictate')} />
            <IconButton
              icon="voice"
              variant="accent"
              accessibilityLabel={t('composer.voice')}
            />
            <IconButton
              icon="send"
              variant="accent"
              disabled
              accessibilityLabel={t('composer.field')}
            />
          </View>
        </Section>

        <Section title={t('gallery.chips')}>
          <View style={styles.wrap}>
            <Chip
              testID="chip-search"
              icon="web"
              label={t('gallery.chipSearch')}
              selected={chips.search}
              onPress={() => setChips({...chips, search: !chips.search})}
            />
            <Chip
              icon="think"
              label={t('gallery.chipThink')}
              selected={chips.think}
              onPress={() => setChips({...chips, think: !chips.think})}
            />
            {chips.file ? (
              <Chip
                icon="attach"
                label={t('gallery.chipFile')}
                onRemove={() => setChips({...chips, file: false})}
              />
            ) : null}
          </View>
        </Section>

        <Section title={t('gallery.rows')}>
          <View style={styles.rows}>
            <ListRow
              icon="sparkles"
              title={t('gallery.rowPersonalization')}
              chevron
              onPress={noop}
            />
            <ListRow
              icon="folder"
              title={t('gallery.rowStorage')}
              subtitle={t('gallery.rowModelSubtitle')}
              value={t('gallery.rowStorageValue')}
              chevron
              onPress={noop}
            />
            <ListRow
              title={t('appearance.haptics')}
              trailing={
                <Toggle
                  testID="gallery-toggle"
                  value={toggle}
                  onValueChange={setToggle}
                  accessibilityLabel={t('appearance.haptics')}
                />
              }
            />
            <ListRow
              icon="delete"
              title={t('gallery.rowDelete')}
              destructive
              onPress={noop}
            />
          </View>
        </Section>

        <Section title={t('gallery.fields')}>
          <TextField
            testID="gallery-field"
            label={t('gallery.fieldLabel')}
            placeholder={t('gallery.fieldPlaceholder')}
            value={name}
            onChangeText={setName}
            clearable
            error={name.length > 40 ? t('gallery.fieldError') : undefined}
          />
          <TextField
            shape="pill"
            icon="search"
            placeholder={t('drawer.search')}
          />
        </Section>

        <Section title={t('gallery.feedback')}>
          <InlineError message={t('errors.generation')} onRetry={noop} />
          <View style={styles.wrap}>
            <Button
              testID="show-toast"
              label={t('gallery.showToast')}
              variant="secondary"
              onPress={() =>
                toast.show({
                  message: t('gallery.toastExample'),
                  kind: 'success',
                  duration: 4000,
                })
              }
            />
            <Button
              testID="open-sheet"
              label={t('gallery.openSheet')}
              variant="secondary"
              onPress={() => {
                sheet.current?.present().catch(() => {});
              }}
            />
            <ContextMenu
              items={[
                {id: 'copy', title: t('chatRow.rename'), icon: 'rename'},
                {
                  id: 'pin',
                  title: t('chatRow.pin'),
                  icon: 'pin',
                  checked: true,
                },
                {
                  id: 'delete',
                  title: t('chatRow.delete'),
                  icon: 'delete',
                  destructive: true,
                },
              ]}
              onSelect={id => toast.show({message: id})}>
              <Button
                testID="open-menu"
                label={t('gallery.openMenu')}
                variant="secondary"
              />
            </ContextMenu>
          </View>
        </Section>

        <Section title={t('gallery.loading')}>
          <Skeleton width="70%" />
          <Skeleton />
          <Skeleton width="45%" />
        </Section>

        <Section title={t('gallery.glass')}>
          <View style={styles.glassStage}>
            <View style={styles.stripes}>
              {STRIPES.map(stripe => (
                <View key={stripe} style={styles.stripe(stripe)} />
              ))}
            </View>
            <GlassSurface radius={28} style={styles.glass}>
              <Text variant="calloutStrong">{t('gallery.glassLabel')}</Text>
            </GlassSurface>
          </View>
        </Section>

        <Section title={t('gallery.type')}>
          {TYPE.map(variant => (
            <Text key={variant} variant={variant}>
              {variant}
            </Text>
          ))}
          <Text variant="caption" color="textTertiary">
            {`fakes: ${fakePortNames().join(', ') || 'none'}`}
          </Text>
        </Section>
      </ScrollView>

      <Sheet ref={sheet} title={t('gallery.sheetTitle')} testID="gallery-sheet">
        <Text color="textSecondary" align="center">
          {t('gallery.sheetBody')}
        </Text>
        <Button
          testID="close-sheet"
          label={t('common.done')}
          fullWidth
          size="lg"
          onPress={() => {
            sheet.current?.dismiss().catch(() => {});
          }}
        />
      </Sheet>
    </View>
  );
}

function noop(): void {}

const STRIPES = [0, 1, 2, 3, 4, 5];

function Section({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <View style={styles.section}>
      <Text variant="footnote" color="textSecondary" accessibilityRole="header">
        {title}
      </Text>
      {children}
    </View>
  );
}

const styles = StyleSheet.create((theme, rt) => ({
  screen: {
    flex: 1,
    backgroundColor: theme.colors.background,
  },
  content: {
    paddingHorizontal: theme.spacing.lg,
    paddingTop: theme.spacing.sm,
    paddingBottom: rt.insets.bottom + theme.spacing.xxl,
    gap: theme.spacing.xxl,
  },
  section: {
    gap: theme.spacing.md,
  },
  wrap: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'center',
    gap: theme.spacing.sm,
  },
  rows: {
    marginHorizontal: -theme.spacing.sm,
  },
  glassStage: {
    height: 120,
    borderRadius: theme.radii.lg,
    overflow: 'hidden',
    alignItems: 'center',
    justifyContent: 'center',
  },
  stripes: {
    ...StyleSheet.absoluteFillObject,
    flexDirection: 'row',
  },
  stripe: (index: number) => ({
    flex: 1,
    backgroundColor:
      index % 2 === 0 ? theme.colors.accent : theme.colors.accentSoft,
  }),
  glass: {
    paddingHorizontal: theme.spacing.xxl,
    paddingVertical: theme.spacing.lg,
  },
}));
