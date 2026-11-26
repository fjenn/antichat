import {strFromU8, strToU8, unzipSync, zipSync} from 'fflate';

const CONVERSATIONS_FILE = /(^|\/)conversations(-\d+)?\.json$/i;

function asConversations(parsed: unknown): unknown[] {
  if (Array.isArray(parsed)) {
    return parsed;
  }
  if (parsed && typeof parsed === 'object') {
    const wrapped = (parsed as Record<string, unknown>).conversations;
    return Array.isArray(wrapped) ? wrapped : [parsed];
  }
  return [];
}

/**
 * Reads the conversations out of a ChatGPT data export. Accepts the zip
 * ChatGPT e-mails (any `conversations.json` or `conversations-NNN.json`
 * inside, at any depth) or a bare JSON file.
 *
 * The whole archive is inflated in memory; a multi-gigabyte export with
 * many images needs a streaming reader on the phone (not built).
 */
export function readChatGptArchive(bytes: Uint8Array): unknown[] {
  const isZip = bytes.length > 3 && bytes[0] === 0x50 && bytes[1] === 0x4b;
  if (!isZip) {
    return asConversations(JSON.parse(strFromU8(bytes)));
  }
  const files = unzipSync(bytes, {
    filter: file => CONVERSATIONS_FILE.test(file.name),
  });
  const names = Object.keys(files).sort();
  if (names.length === 0) {
    throw new Error('No conversations.json in this archive');
  }
  const conversations: unknown[] = [];
  for (const name of names) {
    conversations.push(...asConversations(JSON.parse(strFromU8(files[name]))));
  }
  return conversations;
}

/** Packs conversations the way ChatGPT's export does: a zip with conversations.json. */
export function buildChatGptArchive(conversations: unknown[]): Uint8Array {
  return zipSync({
    'conversations.json': strToU8(JSON.stringify(conversations)),
  });
}
