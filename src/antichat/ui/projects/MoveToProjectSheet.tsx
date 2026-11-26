import React, {forwardRef, useState} from 'react';
import {ScrollView, View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {useLive} from '../memory/useLive';
import {
  Button,
  ListRow,
  Sheet,
  TextField,
  toast,
  type SheetHandle,
} from '../primitives';
import {useProjectsUi} from './registry';
import {ps} from './strings';
import {MAX_PROJECT_NAME} from './types';

export interface MoveToProjectSheetProps {
  /** The chat to move; the sheet is empty without one. */
  conversationId: string | null | undefined;
  onMoved?: (projectId: string | null) => void;
  testID?: string;
}

/**
 * "Move to project" for a chat: pick a project, make a new one, or take the
 * chat out of its project. Present it through the ref.
 */
export const MoveToProjectSheet = forwardRef<
  SheetHandle,
  MoveToProjectSheetProps
>(function MoveSheet(
  {conversationId, onMoved, testID = 'move-to-project'},
  ref,
) {
  const projects = useProjectsUi();
  const rows = useLive(projects, () => projects.list());
  const current = useLive(
    projects,
    async () =>
      conversationId ? await projects.projectOf(conversationId) : null,
    [conversationId],
  );
  const [creating, setCreating] = useState(false);
  const [name, setName] = useState('');

  const dismiss = () => {
    setCreating(false);
    setName('');
    if (ref && typeof ref !== 'function') {
      ref.current?.dismiss();
    }
  };

  const move = async (projectId: string | null, label?: string) => {
    if (!conversationId) {
      return;
    }
    try {
      await projects.moveChat(conversationId, projectId);
      toast.show({
        message: projectId ? ps('moved', {name: label ?? ''}) : ps('removed'),
      });
      onMoved?.(projectId);
      dismiss();
    } catch {
      toast.show({message: ps('failed'), kind: 'error'});
    }
  };

  const createAndMove = async () => {
    if (!name.trim()) {
      return;
    }
    try {
      const project = await projects.create(name);
      await move(project.id, project.name);
    } catch {
      toast.show({message: ps('failed'), kind: 'error'});
    }
  };

  return (
    <Sheet ref={ref} testID={testID} title={ps('move')}>
      {creating ? (
        <View style={styles.create}>
          <TextField
            testID={`${testID}-name`}
            value={name}
            onChangeText={setName}
            placeholder={ps('namePlaceholder')}
            maxLength={MAX_PROJECT_NAME}
            autoFocus
          />
          <Button
            testID={`${testID}-create`}
            label={ps('create')}
            fullWidth
            disabled={name.trim().length === 0}
            onPress={() => {
              createAndMove().catch(() => {});
            }}
          />
        </View>
      ) : (
        <ScrollView style={styles.scroll}>
          <ListRow
            testID={`${testID}-new`}
            icon="add"
            title={ps('newProject')}
            onPress={() => setCreating(true)}
          />
          {(rows ?? []).map(project => (
            <ListRow
              key={project.id}
              testID={`${testID}-${project.id}`}
              icon={project.id === current?.id ? 'check' : 'folder'}
              title={project.name}
              titleLines={1}
              selected={project.id === current?.id}
              onPress={() => {
                move(project.id, project.name).catch(() => {});
              }}
            />
          ))}
          {current ? (
            <ListRow
              testID={`${testID}-remove`}
              icon="close"
              title={ps('removeFromProject')}
              destructive
              onPress={() => {
                move(null).catch(() => {});
              }}
            />
          ) : null}
        </ScrollView>
      )}
    </Sheet>
  );
});

const styles = StyleSheet.create(theme => ({
  scroll: {
    maxHeight: 420,
  },
  create: {
    gap: theme.spacing.lg,
  },
}));
