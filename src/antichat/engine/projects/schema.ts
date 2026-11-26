import {registerMigrations, type MigrationStep} from '../store/schema';

/**
 * The `projects` namespace of antichat.db. M3 reserved the `projects` and
 * `files` tables; this adds the project's memory setting.
 */
export const PROJECTS_NAMESPACE = 'projects';

const steps: MigrationStep[] = [
  {
    version: 1,
    statements: [
      // 'default': the project's chats also see global memories and other
      // chats. 'project': memories and chat references stay inside it.
      "ALTER TABLE projects ADD COLUMN memory_scope TEXT NOT NULL DEFAULT 'default'",
      'ALTER TABLE projects ADD COLUMN archived_at INTEGER',
      'CREATE INDEX projects_listing ON projects (archived_at, updated_at)',
    ],
  },
];

/** Call before the conversation store is initialised (or before `migrate`). */
export function registerProjectMigrations(): void {
  registerMigrations(PROJECTS_NAMESPACE, steps);
}
