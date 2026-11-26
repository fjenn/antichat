import type {Ports} from '..';
import {FakeChat, type FakeChatOptions} from './FakeChat';
import {FakeConnectivity} from './FakeConnectivity';
import {
  FakeConversations,
  type FakeConversationsOptions,
} from './FakeConversations';
import {FakeFiles} from './FakeFiles';
import {FakeMemory} from './FakeMemory';
import {FakeModel, type FakeModelOptions} from './FakeModel';
import {FakeTools} from './FakeTools';
import {FakeVoice} from './FakeVoice';

export {
  FakeChat,
  FakeConnectivity,
  FakeConversations,
  FakeFiles,
  FakeMemory,
  FakeModel,
  FakeTools,
  FakeVoice,
};
export * from './answers';

export interface FakePorts extends Ports {
  chat: FakeChat;
  conversations: FakeConversations;
  model: FakeModel;
  tools: FakeTools;
  memory: FakeMemory;
  files: FakeFiles;
  voice: FakeVoice;
  connectivity: FakeConnectivity;
}

export interface FakePortsOptions {
  chat?: FakeChatOptions;
  conversations?: FakeConversationsOptions;
  model?: FakeModelOptions;
}

/** A complete in-memory backend; the fakes are wired to each other. */
export function createFakePorts(options: FakePortsOptions = {}): FakePorts {
  const connectivity = new FakeConnectivity();
  const conversations = new FakeConversations(options.conversations);
  return {
    connectivity,
    conversations,
    chat: new FakeChat(conversations, options.chat),
    model: new FakeModel(options.model),
    tools: new FakeTools(connectivity),
    memory: new FakeMemory(),
    files: new FakeFiles(),
    voice: new FakeVoice(),
  };
}
