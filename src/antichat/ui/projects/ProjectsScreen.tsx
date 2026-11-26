import React, {useRef, useState} from 'react';
import {FlatList, View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {EmptyState, Header, type ScreenNavigation} from '../memory/parts';
import {useLive} from '../memory/useLive';
import {
  Button,
  IconButton,
  ListRow,
  Sheet,
  Skeleton,
  TextField,
  toast,
  type SheetHandle,
} from '../primitives';
import {useProjectsUi} from './registry';
import {chatCount, ps} from './strings';
import {MAX_PROJECT_NAME} from './types';

/** The list of projects, with "New project". */
export function ProjectsScreen({navigation}: {navigation: ScreenNavigation}) {
  const projects = useProjectsUi();
  const rows = useLive(projects, () => projects.list());
  const [name, setName] = useState('');
  const [busy, setBusy] = useState(false);
  const sheet = useRef<SheetHandle>(null);

  const openCreate = () => {
    setName('');
    sheet.current?.present();
  };

  const create = async () => {
    if (!name.trim() || busy) {
      return;
    }
    setBusy(true);
    try {
      const project = await projects.create(name);
      await sheet.current?.dismiss();
      navigation.navigate('Project', {projectId: project.id});
    } catch {
      toast.show({message: ps('failed'), kind: 'error'});
    } finally {
      setBusy(false);
    }
  };

  return (
    <View testID="projects-screen" style={styles.screen}>
      <Header
        title={ps('title')}
        onBack={() => navigation.goBack()}
        trailing={
          <IconButton
            testID="projects-add"
            icon="add"
            variant="glass"
            accessibilityLabel={ps('newProject')}
            onPress={openCreate}
          />
        }
      />
      <FlatList
        data={rows ?? []}
        keyExtractor={row => row.id}
        contentContainerStyle={styles.content}
        ListHeaderComponent={
          <ListRow
            testID="projects-new"
            icon="add"
            title={ps('newProject')}
            onPress={openCreate}
          />
        }
        renderItem={({item}) => (
          <ListRow
            testID={`project-row-${item.id}`}
            icon="folder"
            title={item.name}
            titleLines={1}
            subtitle={chatCount(item.chatCount)}
            chevron
            onPress={() => navigation.navigate('Project', {projectId: item.id})}
          />
        )}
        ListEmptyComponent={
          rows === undefined ? (
            <View style={styles.loading}>
              <Skeleton height={20} width="70%" />
              <Skeleton height={20} width="50%" />
            </View>
          ) : (
            <EmptyState
              testID="projects-empty"
              icon="folder"
              title={ps('empty')}
              hint={ps('emptyHint')}
            />
          )
        }
      />
      <Sheet ref={sheet} testID="project-create" title={ps('newProject')}>
        <TextField
          testID="project-create-name"
          value={name}
          onChangeText={setName}
          placeholder={ps('namePlaceholder')}
          maxLength={MAX_PROJECT_NAME}
          returnKeyType="done"
          onSubmitEditing={() => {
            create().catch(() => {});
          }}
        />
        <Button
          testID="project-create-save"
          label={ps('create')}
          fullWidth
          loading={busy}
          disabled={name.trim().length === 0}
          onPress={() => {
            create().catch(() => {});
          }}
        />
      </Sheet>
    </View>
  );
}

const styles = StyleSheet.create((theme, rt) => ({
  screen: {
    flex: 1,
    backgroundColor: theme.colors.background,
  },
  content: {
    paddingHorizontal: theme.spacing.md,
    paddingBottom: rt.insets.bottom + theme.spacing.xxl,
  },
  loading: {
    gap: theme.spacing.lg,
    padding: theme.spacing.md,
  },
}));
