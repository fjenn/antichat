import '../../../testing/setup';

import type {CapabilityMap, ModelView} from '../../../contracts';
import {translate} from '../../../locales';
import {allCapabilityLines} from '../capabilityList';
import {bytesOnPhone, storageBreakdown, type StorageProbe} from '../storage';

const yes = {available: true} as const;
const needs = (ram: number) =>
  ({
    available: false,
    reason: {kind: 'needs_class', minClass: 'C', marketedRamGb: ram},
  }) as const;

const map = (patch: Partial<CapabilityMap> = {}): CapabilityMap => ({
  deviceClass: 'D',
  modelId: 'm',
  contextSize: 16384,
  vision: yes,
  imageInput: 'model',
  audioInput: yes,
  imageGeneration: yes,
  voiceMode: yes,
  embeddings: yes,
  research: yes,
  followUps: yes,
  renderHtml: yes,
  backgroundMemory: yes,
  tools: yes,
  thinking: yes,
  thinkingAlwaysOn: false,
  searchQueriesPerTurn: 3,
  maxTools: 5,
  ...patch,
});

describe('what this phone can do', () => {
  it('lists everything as working on a large phone', () => {
    const lines = allCapabilityLines(translate, map());
    expect(lines.every(line => line.available)).toBe(true);
    expect(lines.map(line => line.id)).toEqual([
      'chat',
      'search',
      'files',
      'voiceInput',
      'photos',
      'voiceMode',
      'imageGeneration',
      'research',
      'memory',
      'thinking',
      'longChats',
    ]);
    expect(lines.find(line => line.id === 'longChats')!.detail).toBe(
      'Remembers about 12,000 words of a chat',
    );
  });

  it('gives the reason for what a small phone cannot do', () => {
    const lines = allCapabilityLines(
      translate,
      map({
        deviceClass: 'A',
        contextSize: 4096,
        vision: needs(8),
        imageInput: 'ocr',
        imageGeneration: needs(8),
        voiceMode: needs(6),
        research: needs(8),
        backgroundMemory: needs(6),
        thinking: {available: false, reason: {kind: 'model_lacks'}},
      }),
    );
    const line = (id: string) => lines.find(item => item.id === id)!;
    expect(line('imageGeneration')).toMatchObject({
      available: false,
      detail: 'Needs a phone with 8 GB memory',
    });
    expect(line('voiceMode').detail).toBe('Needs a phone with 6 GB memory');
    expect(line('thinking').detail).toBe('The assistant in use can’t do this');
    // Photos still do something useful: their text is read.
    expect(line('photosOcr').available).toBe(true);
    expect(line('photos').available).toBe(false);
    // The basics always work.
    expect(line('chat').available).toBe(true);
    expect(line('files').available).toBe(true);
  });

  it('never uses model jargon', () => {
    const text = allCapabilityLines(translate, map())
      .map(line => `${line.title} ${line.detail ?? ''}`)
      .join(' ');
    expect(text).not.toMatch(/token|context|GGUF|quant|embedding|vision/i);
  });
});

const GB = 1000 ** 3;
const model = (state: ModelView['state'], gb = 5): ModelView => ({
  id: 'm',
  displayName: 'M',
  downloadBytes: gb * GB,
  unrestricted: false,
  licenceName: 'x',
  openSource: true,
  recommended: true,
  supported: true,
  vision: false,
  state,
});

describe('storage', () => {
  const probe = (patch: Partial<StorageProbe> = {}): StorageProbe => ({
    freeBytes: async () => 40 * GB,
    totalBytes: async () => 128 * GB,
    chatBytes: async () => 0.2 * GB,
    voiceBytes: async () => 0,
    imageBytes: async () => 0,
    ...patch,
  });

  it('counts a whole model when installed and the received part while downloading', () => {
    expect(bytesOnPhone(model({status: 'loaded'} as ModelView['state']))).toBe(
      5 * GB,
    );
    expect(
      bytesOnPhone(
        model({
          status: 'downloading',
          paused: true,
          progress: {receivedBytes: GB, totalBytes: 5 * GB, fraction: 0.2},
        }),
      ),
    ).toBe(GB);
    expect(bytesOnPhone(model({status: 'not_installed'}))).toBe(0);
  });

  it('splits the phone into models, chats, other and free', async () => {
    const made = await storageBreakdown(
      [model({status: 'ready'}), model({status: 'not_installed'}, 3)],
      probe(),
    );
    expect(made.models).toBe(5 * GB);
    expect(made.chats).toBe(0.2 * GB);
    expect(made.free).toBe(40 * GB);
    expect(made.total).toBe(128 * GB);
    expect(made.other).toBeCloseTo(128 * GB - 40 * GB - 5.2 * GB, -3);
  });

  it('still adds up when a read fails', async () => {
    const made = await storageBreakdown(
      [model({status: 'ready'})],
      probe({
        totalBytes: async () => {
          throw new Error('no');
        },
      }),
    );
    expect(made.total).toBe(made.free + made.models + made.chats);
    expect(made.other).toBe(0);
  });
});
