/**
 * "What this phone can do" as a plain list, from the engine's capability
 * map. Unavailable features are hidden everywhere else in the app; this is
 * the one place they are listed, each with its reason.
 */
import {V1} from '../../app/scope';
import type {Capability, CapabilityMap} from '../../contracts';
import type {MessageKey, Translate} from '../../locales';
import type {IconName} from '../primitives';

export interface CapabilityLine {
  id: string;
  icon: IconName;
  title: string;
  /** A note for an available feature, or the reason for a missing one. */
  detail?: string;
  available: boolean;
}

const WORDS_PER_TOKEN = 0.75;

function reason(t: Translate, capability: Capability): string {
  const why = capability.reason;
  if (why?.kind === 'needs_class') {
    return t('capabilities.needs', {ram: why.marketedRamGb});
  }
  if (why?.kind === 'model_lacks') {
    return t('capabilities.modelLacks');
  }
  return t('capabilities.notOffered');
}

/** Every line, in or out of the first version's scope. */
export function allCapabilityLines(
  t: Translate,
  map: CapabilityMap,
): CapabilityLine[] {
  const always = (
    id: string,
    icon: IconName,
    title: MessageKey,
    detail?: string,
  ): CapabilityLine => ({id, icon, title: t(title), detail, available: true});
  const feature = (
    id: string,
    icon: IconName,
    title: MessageKey,
    capability: Capability,
    detail?: string,
  ): CapabilityLine => ({
    id,
    icon,
    title: t(title),
    detail: capability.available ? detail : reason(t, capability),
    available: capability.available,
  });
  const words = Math.round((map.contextSize * WORDS_PER_TOKEN) / 1000) * 1000;

  const lines: CapabilityLine[] = [
    always('chat', 'sparkles', 'capabilities.chat', t('capabilities.chatHint')),
    feature(
      'search',
      'web',
      'capabilities.search',
      map.tools,
      t('capabilities.searchHint'),
    ),
    always('files', 'document', 'capabilities.files'),
    always('voiceInput', 'mic', 'capabilities.voiceInput'),
  ];
  if (map.vision.available) {
    lines.push(always('photos', 'image', 'capabilities.photos'));
  } else {
    lines.push(
      always(
        'photosOcr',
        'image',
        'capabilities.photosOcr',
        t('capabilities.photosOcrHint'),
      ),
      feature('photos', 'image', 'capabilities.photos', map.vision),
    );
  }
  lines.push(
    feature('voiceMode', 'voice', 'capabilities.voiceMode', map.voiceMode),
    feature(
      'imageGeneration',
      'appearance',
      'capabilities.imageGeneration',
      map.imageGeneration,
    ),
    feature('research', 'search', 'capabilities.research', map.research),
    feature('memory', 'memory', 'capabilities.memory2', map.backgroundMemory),
    feature('thinking', 'think', 'capabilities.thinking', map.thinking),
    always(
      'longChats',
      'temporary',
      'capabilities.longChats',
      t('capabilities.longChatsHint', {
        words: words.toLocaleString('en-US'),
      }),
    ),
  );
  return lines;
}

/** The lines the first version shows: only what it ships (`app/scope`). */
export function capabilityLines(
  t: Translate,
  map: CapabilityMap,
): CapabilityLine[] {
  const hidden = new Set<string>([
    ...(V1.attachments ? [] : ['files', 'photos', 'photosOcr']),
    ...(V1.voiceMode ? [] : ['voiceMode']),
    ...(V1.images ? [] : ['imageGeneration']),
    ...(V1.research ? [] : ['research']),
  ]);
  return allCapabilityLines(t, map).filter(line => !hidden.has(line.id));
}
