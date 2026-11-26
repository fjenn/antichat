import type {ToolView} from '../../contracts';
import type {MessageKey} from '../../locales';
import type {IconName} from '../primitives';

export const TOOL_ICONS: Record<ToolView['kind'], IconName> = {
  search: 'web',
  think: 'think',
  image: 'image',
  research: 'research',
  study: 'study',
  calculator: 'calculator',
  connector: 'sparkles',
  other: 'sparkles',
};

export const toolName = (kind: ToolView['kind']): MessageKey =>
  `tools.${kind}` as MessageKey;

export const toolChipName = (kind: ToolView['kind']): MessageKey =>
  `toolChips.${kind}` as MessageKey;
