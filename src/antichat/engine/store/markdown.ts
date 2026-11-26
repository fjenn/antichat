import type {NodeRecord, SessionMeta} from './types';

export interface MarkdownOptions {
  userLabel?: string;
  assistantLabel?: string;
}

/** One chat's visible thread as a Markdown document. */
export function exportMarkdown(
  meta: Pick<SessionMeta, 'title' | 'createdAt'>,
  path: NodeRecord[],
  options: MarkdownOptions = {},
): string {
  const userLabel = options.userLabel ?? 'You';
  const assistantLabel = options.assistantLabel ?? 'AntiChat';
  const lines: string[] = [`# ${meta.title.replace(/\s+/g, ' ').trim()}`, ''];
  lines.push(`_${new Date(meta.createdAt).toISOString().slice(0, 10)}_`, '');
  for (const node of path) {
    const images: unknown[] = Array.isArray(node.payload.metadata?.imageUris)
      ? node.payload.metadata.imageUris
      : [];
    const text = node.text.trim();
    if (text.length === 0 && images.length === 0) {
      continue;
    }
    lines.push(`**${node.role === 'user' ? userLabel : assistantLabel}**`, '');
    if (images.length > 0) {
      lines.push(
        `_[${images.length} image${images.length === 1 ? '' : 's'}]_`,
        '',
      );
    }
    if (text.length > 0) {
      lines.push(text, '');
    }
  }
  return (
    lines
      .join('\n')
      .replace(/\n{3,}/g, '\n\n')
      .trimEnd() + '\n'
  );
}
