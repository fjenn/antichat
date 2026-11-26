/**
 * Turns a chat into something the system share sheet can take: Markdown,
 * plain text, or ChatGPT's export format. The real store writes all three
 * (`adapters/history.ts`); with the fake backend the same shapes are built
 * from the fake thread, so the sheet works in UI tests too.
 */
import {getPorts} from '../../adapters';
import {
  exportFileName,
  isHistoryPort,
  threadAsPlainText,
  type ExportFormat,
  type ExportedChat,
  type HistoryMessage,
} from '../../adapters/history';
import type {ConversationView} from '../../contracts';
import {translate} from '../../locales';

export const EXPORT_FORMATS: readonly ExportFormat[] = [
  'markdown',
  'text',
  'chatgpt',
];

function labels() {
  return {user: translate('share.you'), assistant: translate('app.name')};
}

function markdownOf(
  title: string,
  createdAt: number,
  messages: readonly HistoryMessage[],
): string {
  const names = labels();
  const lines = [`# ${title}`, ''];
  lines.push(`_${new Date(createdAt).toISOString().slice(0, 10)}_`, '');
  for (const message of messages) {
    if (!message.text.trim()) {
      continue;
    }
    lines.push(
      `**${message.role === 'user' ? names.user : names.assistant}**`,
      '',
      message.text.trim(),
      '',
    );
  }
  return lines.join('\n').trimEnd() + '\n';
}

/** A linear thread in the shape of ChatGPT's `conversations.json`. */
function chatGptOf(
  conversation: ConversationView,
  messages: readonly HistoryMessage[],
): Record<string, unknown> {
  const mapping: Record<string, unknown> = {
    root: {
      id: 'root',
      message: null,
      parent: null,
      children: messages.length > 0 ? [messages[0].id] : [],
    },
  };
  messages.forEach((message, index) => {
    mapping[message.id] = {
      id: message.id,
      message: {
        id: message.id,
        author: {role: message.role},
        create_time: message.createdAt / 1000,
        content: {content_type: 'text', parts: [message.text]},
        status: 'finished_successfully',
      },
      parent: index === 0 ? 'root' : messages[index - 1].id,
      children: index + 1 < messages.length ? [messages[index + 1].id] : [],
    };
  });
  return {
    title: conversation.title,
    create_time: conversation.createdAt / 1000,
    update_time: conversation.updatedAt / 1000,
    mapping,
    current_node: messages[messages.length - 1]?.id ?? 'root',
    conversation_id: conversation.id,
  };
}

export async function exportChat(
  conversation: ConversationView,
  format: ExportFormat,
): Promise<ExportedChat> {
  const {conversations, chat} = getPorts();
  if (isHistoryPort(conversations)) {
    return conversations.exportChat(conversation.id, format, labels());
  }
  const title = conversation.title || translate('shell.untitledChat');
  const messages: HistoryMessage[] = chat
    .messages(conversation.id)
    .map(message => ({
      id: message.id,
      role: message.role,
      text: message.text,
      createdAt: message.createdAt,
    }));
  switch (format) {
    case 'markdown':
      return {
        format,
        fileName: exportFileName(title, 'md'),
        mimeType: 'text/markdown',
        content: markdownOf(title, conversation.createdAt, messages),
      };
    case 'chatgpt':
      return {
        format,
        fileName: exportFileName(title, 'json'),
        mimeType: 'application/json',
        content: JSON.stringify([chatGptOf(conversation, messages)], null, 2),
      };
    default:
      return {
        format,
        fileName: exportFileName(title, 'txt'),
        mimeType: 'text/plain',
        content: threadAsPlainText(title, messages, labels()),
      };
  }
}

/**
 * Hands an export to the system share sheet. Plain text goes as text (so it
 * can be pasted into a message); Markdown and JSON go as files.
 */
export async function shareExport(exported: ExportedChat): Promise<void> {
  const Share = require('react-native-share').default;
  if (exported.format === 'text') {
    await Share.open({message: exported.content, failOnCancel: false});
    return;
  }
  const RNFS = require('@dr.pogodin/react-native-fs');
  const directory = `${RNFS.CachesDirectoryPath}/antichat-share`;
  await RNFS.mkdir(directory);
  const path = `${directory}/${exported.fileName}`;
  await RNFS.writeFile(path, exported.content, 'utf8');
  await Share.open({
    url: `file://${path}`,
    type: exported.mimeType,
    filename: exported.fileName,
    failOnCancel: false,
  });
}
