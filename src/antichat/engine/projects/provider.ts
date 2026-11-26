/**
 * Request provider for projects: a chat inside a project gets that
 * project's instructions and the names of its files; a chat outside gets
 * nothing. The block is a `session` block (it changes only when the user
 * edits the project), placed before the memory block.
 */
import type {TokenCounter} from '../context/tokenCounter';
import type {
  Contribution,
  RequestContext,
  RequestProvider,
} from '../prompt/types';
import type {ProjectStore} from './ProjectStore';
import type {Project, ProjectFile} from './types';

export const PROJECT_PROVIDER_ID = 'antichat.project';
export const PROJECT_BLOCK_ID = 'project';

/** Tokens the project's instructions may take: about 8% of the window. */
export function projectInstructionBudget(nCtx: number): number {
  return Math.max(200, Math.min(1500, Math.round(nCtx * 0.08)));
}

export interface ProjectRequestMeta {
  id: string;
  name: string;
  /** The instructions were cut to fit the budget. */
  truncated: boolean;
  files: number;
}

/** Cuts `text` to `tokens` at a line or sentence end. */
export async function fitToTokens(
  text: string,
  tokens: number,
  counter: TokenCounter,
): Promise<{text: string; truncated: boolean}> {
  const trimmed = text.trim();
  if ((await counter.countText(trimmed)) <= tokens) {
    return {text: trimmed, truncated: false};
  }
  let low = 0;
  let high = trimmed.length;
  while (low < high) {
    const middle = Math.ceil((low + high) / 2);
    if ((await counter.countText(trimmed.slice(0, middle))) <= tokens) {
      low = middle;
    } else {
      high = middle - 1;
    }
  }
  const cut = trimmed.slice(0, low);
  const stop = Math.max(
    cut.lastIndexOf('\n'),
    cut.lastIndexOf('. '),
    cut.lastIndexOf('! '),
    cut.lastIndexOf('? '),
  );
  return {
    text: (stop > low * 0.5 ? cut.slice(0, stop + 1) : cut).trimEnd(),
    truncated: true,
  };
}

export function renderProjectBlock(
  project: Project,
  instructions: string,
  files: ProjectFile[],
): string {
  const lines = [`This chat is part of the user's project "${project.name}".`];
  if (instructions) {
    lines.push(
      `The user's instructions for every chat in this project:\n${instructions}`,
    );
  }
  if (files.length > 0) {
    const names = files.slice(0, 20).map(file => file.name);
    lines.push(`Files attached to the project: ${names.join(', ')}.`);
  }
  return lines.join('\n');
}

export interface ProjectProviderOptions {
  projects: ProjectStore;
  budget?: (nCtx: number) => number;
}

export function createProjectProvider(
  options: ProjectProviderOptions,
): RequestProvider {
  return {
    id: PROJECT_PROVIDER_ID,
    order: 40,
    contribute: async (
      context: RequestContext,
    ): Promise<Contribution | void> => {
      const {session, runtime} = context;
      // A temporary chat is never in a project; a chat without a row yet
      // cannot be either.
      if (!session.id || session.temporary) {
        return;
      }
      const project = await options.projects.projectOfSession(session.id);
      if (!project || project.archivedAt !== null) {
        return;
      }
      const files = await options.projects.listFiles(project.id);
      const fitted = await fitToTokens(
        project.instructions,
        (options.budget ?? projectInstructionBudget)(runtime.nCtx),
        runtime.tokenCounter,
      );
      const meta: ProjectRequestMeta = {
        id: project.id,
        name: project.name,
        truncated: fitted.truncated,
        files: files.length,
      };
      return {
        systemBlocks: [
          {
            id: PROJECT_BLOCK_ID,
            slot: 'session',
            order: 40,
            text: renderProjectBlock(project, fitted.text, files),
          },
        ],
        meta: {project: meta},
      };
    },
  };
}
