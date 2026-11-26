import React, {useRef, useState} from 'react';
import {ScrollView, View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {
  EmptyState,
  Header,
  SectionLabel,
  shortDate,
  type ScreenNavigation,
} from '../memory/parts';
import {useLive} from '../memory/useLive';
import {
  Button,
  ContextMenu,
  IconButton,
  ListRow,
  Sheet,
  Text,
  TextField,
  toast,
  type SheetHandle,
} from '../primitives';
import {openChat} from './openChat';
import {useProjectFilesSection, useProjectsUi} from './registry';
import {ps} from './strings';
import {MAX_PROJECT_INSTRUCTIONS, MAX_PROJECT_NAME} from './types';

export interface ProjectScreenProps {
  navigation: ScreenNavigation;
  route: {params: {projectId: string}};
}

/** One project: instructions, files, its chats, "new chat in project". */
export function ProjectScreen({navigation, route}: ProjectScreenProps) {
  const {projectId} = route.params;
  const projects = useProjectsUi();
  const FilesSection = useProjectFilesSection();
  const project = useLive(projects, () => projects.get(projectId), [projectId]);
  const chats = useLive(projects, () => projects.chats(projectId), [projectId]);
  const [draft, setDraft] = useState('');
  const renameSheet = useRef<SheetHandle>(null);
  const instructionsSheet = useRef<SheetHandle>(null);
  const deleteSheet = useRef<SheetHandle>(null);

  if (project === undefined) {
    return (
      <View style={styles.screen}>
        <Header title="" onBack={() => navigation.goBack()} />
      </View>
    );
  }
  if (project === null) {
    return (
      <View testID="project-missing" style={styles.screen}>
        <Header title={ps('title')} onBack={() => navigation.goBack()} />
        <EmptyState icon="folder" title={ps('missing')} />
      </View>
    );
  }

  const failed = () => toast.show({message: ps('failed'), kind: 'error'});

  const menu = (id: string) => {
    if (id === 'rename') {
      setDraft(project.name);
      renameSheet.current?.present();
    } else if (id === 'delete') {
      deleteSheet.current?.present();
    }
  };

  const rename = async () => {
    if (!draft.trim()) {
      return;
    }
    await projects.update(projectId, {name: draft});
    await renameSheet.current?.dismiss();
  };

  const saveInstructions = async () => {
    await projects.update(projectId, {instructions: draft.trim()});
    await instructionsSheet.current?.dismiss();
  };

  const remove = async () => {
    await deleteSheet.current?.dismiss();
    navigation.goBack();
    await projects.remove(projectId);
    toast.show({message: ps('deleted')});
  };

  const newChat = async () => {
    openChat(navigation, await projects.startChat(projectId));
  };

  return (
    <View testID="project-screen" style={styles.screen}>
      <Header
        title={project.name}
        onBack={() => navigation.goBack()}
        trailing={
          <ContextMenu
            testID="project-menu"
            items={[
              {id: 'rename', title: ps('rename'), icon: 'rename'},
              {
                id: 'delete',
                title: ps('delete'),
                icon: 'delete',
                destructive: true,
              },
            ]}
            onSelect={menu}>
            <IconButton
              testID="project-more"
              icon="more"
              variant="glass"
              accessibilityLabel={ps('more')}
            />
          </ContextMenu>
        }
      />
      <ScrollView contentContainerStyle={styles.content}>
        <Button
          testID="project-new-chat"
          label={ps('newChat')}
          icon="newChat"
          size="lg"
          fullWidth
          onPress={() => {
            newChat().catch(failed);
          }}
        />

        <SectionLabel>{ps('instructions')}</SectionLabel>
        <ListRow
          testID="project-instructions"
          title={project.instructions || ps('instructionsEmpty')}
          subtitle={project.instructions ? undefined : ps('instructionsHint')}
          titleLines={3}
          chevron
          onPress={() => {
            setDraft(project.instructions);
            instructionsSheet.current?.present();
          }}
          style={styles.card}
        />

        <SectionLabel>{ps('files')}</SectionLabel>
        <View testID="project-files">
          {FilesSection ? (
            <FilesSection projectId={projectId} />
          ) : (
            <DefaultFiles projectId={projectId} />
          )}
        </View>

        <SectionLabel>{ps('chatsTitle')}</SectionLabel>
        {(chats ?? []).map(chat => (
          <ListRow
            key={chat.id}
            testID={`project-chat-${chat.id}`}
            title={chat.title || ps('untitled')}
            titleLines={1}
            value={shortDate(chat.updatedAt)}
            onPress={() => openChat(navigation, chat.id)}
          />
        ))}
        {chats && chats.length === 0 ? (
          <Text
            testID="project-chats-empty"
            variant="callout"
            color="textTertiary"
            style={styles.note}>
            {ps('chatsEmpty')}
          </Text>
        ) : null}
      </ScrollView>

      <Sheet
        ref={renameSheet}
        testID="project-rename"
        title={ps('renameTitle')}>
        <TextField
          testID="project-rename-name"
          value={draft}
          onChangeText={setDraft}
          placeholder={ps('namePlaceholder')}
          maxLength={MAX_PROJECT_NAME}
        />
        <Button
          testID="project-rename-save"
          label={ps('save')}
          fullWidth
          disabled={draft.trim().length === 0}
          onPress={() => {
            rename().catch(failed);
          }}
        />
      </Sheet>

      <Sheet
        ref={instructionsSheet}
        testID="project-instructions-editor"
        title={ps('instructions')}>
        <TextField
          testID="project-instructions-text"
          value={draft}
          onChangeText={setDraft}
          placeholder={ps('instructionsPlaceholder')}
          multiline
          maxLength={MAX_PROJECT_INSTRUCTIONS}
        />
        <Button
          testID="project-instructions-save"
          label={ps('save')}
          fullWidth
          onPress={() => {
            saveInstructions().catch(failed);
          }}
        />
      </Sheet>

      <Sheet
        ref={deleteSheet}
        testID="project-delete"
        title={ps('deleteTitle')}>
        <Text variant="callout" color="textSecondary" align="center">
          {ps('deleteBody')}
        </Text>
        <Button
          testID="project-delete-yes"
          label={ps('delete')}
          variant="destructive"
          fullWidth
          onPress={() => {
            remove().catch(failed);
          }}
        />
        <Button
          label={ps('cancel')}
          variant="secondary"
          fullWidth
          onPress={() => deleteSheet.current?.dismiss()}
        />
      </Sheet>
    </View>
  );
}

/** File names only; M10 replaces this through `setProjectFilesSection`. */
function DefaultFiles({projectId}: {projectId: string}) {
  const projects = useProjectsUi();
  const files = useLive(projects, () => projects.files(projectId), [projectId]);
  if (!files || files.length === 0) {
    return (
      <Text variant="callout" color="textTertiary" style={styles.note}>
        {ps('filesEmpty')}
      </Text>
    );
  }
  return (
    <>
      {files.map(file => (
        <ListRow
          key={file.id}
          testID={`project-file-${file.id}`}
          icon="attach"
          title={file.name}
          titleLines={1}
          value={
            file.status === 'pending'
              ? ps('filePending')
              : file.status === 'failed'
                ? ps('fileFailed')
                : undefined
          }
        />
      ))}
    </>
  );
}

const styles = StyleSheet.create((theme, rt) => ({
  screen: {
    flex: 1,
    backgroundColor: theme.colors.background,
  },
  content: {
    paddingTop: theme.spacing.sm,
    paddingHorizontal: theme.spacing.md,
    paddingBottom: rt.insets.bottom + theme.spacing.xxl,
  },
  card: {
    borderRadius: theme.radii.md,
    backgroundColor: theme.colors.surface,
  },
  note: {
    paddingHorizontal: theme.spacing.md,
    paddingVertical: theme.spacing.sm,
  },
}));
