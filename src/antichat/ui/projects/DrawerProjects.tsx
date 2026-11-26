import React from 'react';
import {View} from 'react-native';

import {useLive} from '../memory/useLive';
import {ListRow} from '../primitives';
import {useProjectsUi} from './registry';
import {ps} from './strings';

export interface DrawerProjectsProps {
  onOpenProject: (projectId: string) => void;
  /** Opens the full list (where "New project" is). */
  onOpenAll: () => void;
  /** Projects shown before "All projects" takes over. */
  limit?: number;
}

/** The drawer's Projects block: the entry row and the most recent projects. */
export function DrawerProjects({
  onOpenProject,
  onOpenAll,
  limit = 3,
}: DrawerProjectsProps) {
  const projects = useProjectsUi();
  const rows = useLive(projects, () => projects.list()) ?? [];
  return (
    <View testID="drawer-projects">
      <ListRow
        testID="drawer-projects-all"
        icon="folder"
        title={rows.length > limit ? ps('seeAll') : ps('title')}
        onPress={onOpenAll}
      />
      {rows.slice(0, limit).map(project => (
        <ListRow
          key={project.id}
          testID={`drawer-project-${project.id}`}
          icon="folder"
          title={project.name}
          titleLines={1}
          onPress={() => onOpenProject(project.id)}
        />
      ))}
    </View>
  );
}
