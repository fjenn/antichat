/**
 * Port contracts: the only surface UI milestones and engine milestones share.
 * UI code imports types from here and instances from `../adapters`.
 */
export * from './common';
export * from './chat';
export * from './conversation';
export * from './model';
export * from './tools';
export * from './memory';
export * from './files';
export * from './voice';
export * from './connectivity';

import type {ChatPort} from './chat';
import type {Connectivity} from './connectivity';
import type {ConversationPort} from './conversation';
import type {FilesPort} from './files';
import type {MemoryPort} from './memory';
import type {ModelPort} from './model';
import type {ToolsPort} from './tools';
import type {VoicePort} from './voice';

export interface Ports {
  chat: ChatPort;
  conversations: ConversationPort;
  model: ModelPort;
  tools: ToolsPort;
  memory: MemoryPort;
  files: FilesPort;
  voice: VoicePort;
  connectivity: Connectivity;
}

export type PortName = keyof Ports;
