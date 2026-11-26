/**
 * The one icon set, drawn the same on both platforms. Screens name an icon by
 * role; swapping the glyph happens here.
 */
import type {ComponentType} from 'react';
import React from 'react';
import Svg, {Path} from 'react-native-svg';
import Archive from 'lucide-react-native/icons/archive';
import ArrowDown from 'lucide-react-native/icons/arrow-down';
import ArrowUp from 'lucide-react-native/icons/arrow-up';
import AudioLines from 'lucide-react-native/icons/audio-lines';
import Calculator from 'lucide-react-native/icons/calculator';
import ArchiveRestore from 'lucide-react-native/icons/archive-restore';
import Braces from 'lucide-react-native/icons/braces';
import Camera from 'lucide-react-native/icons/camera';
import Check from 'lucide-react-native/icons/check';
import ChevronDown from 'lucide-react-native/icons/chevron-down';
import ChevronLeft from 'lucide-react-native/icons/chevron-left';
import ChevronRight from 'lucide-react-native/icons/chevron-right';
import CircleAlert from 'lucide-react-native/icons/circle-alert';
import ClipboardGlyph from 'lucide-react-native/icons/clipboard';
import Clock from 'lucide-react-native/icons/clock';
import Copy from 'lucide-react-native/icons/copy';
import Ellipsis from 'lucide-react-native/icons/ellipsis';
import FileText from 'lucide-react-native/icons/file-text';
import Folder from 'lucide-react-native/icons/folder';
import GitBranch from 'lucide-react-native/icons/git-branch';
import Globe from 'lucide-react-native/icons/globe';
import GraduationCap from 'lucide-react-native/icons/graduation-cap';
import Image from 'lucide-react-native/icons/image';
import Info from 'lucide-react-native/icons/info';
import LayoutGrid from 'lucide-react-native/icons/layout-grid';
import LetterText from 'lucide-react-native/icons/letter-text';
import LifeBuoy from 'lucide-react-native/icons/life-buoy';
import Lightbulb from 'lucide-react-native/icons/lightbulb';
import Lock from 'lucide-react-native/icons/lock';
import LockOpen from 'lucide-react-native/icons/lock-open';
import MapPin from 'lucide-react-native/icons/map-pin';
import MessageCircleDashed from 'lucide-react-native/icons/message-circle-dashed';
import Mic from 'lucide-react-native/icons/mic';
import Palette from 'lucide-react-native/icons/palette';
import Paperclip from 'lucide-react-native/icons/paperclip';
import Pencil from 'lucide-react-native/icons/pencil';
import Pin from 'lucide-react-native/icons/pin';
import PinOff from 'lucide-react-native/icons/pin-off';
import Plus from 'lucide-react-native/icons/plus';
import RefreshCw from 'lucide-react-native/icons/refresh-cw';
import Search from 'lucide-react-native/icons/search';
import Settings from 'lucide-react-native/icons/settings';
import Share from 'lucide-react-native/icons/share';
import Sparkles from 'lucide-react-native/icons/sparkles';
import Reply from 'lucide-react-native/icons/corner-down-right';
import Square from 'lucide-react-native/icons/square';
import SquarePen from 'lucide-react-native/icons/square-pen';
import Telescope from 'lucide-react-native/icons/telescope';
import TextSelect from 'lucide-react-native/icons/text-select';
import ThumbsDown from 'lucide-react-native/icons/thumbs-down';
import ThumbsUp from 'lucide-react-native/icons/thumbs-up';
import Trash from 'lucide-react-native/icons/trash-2';
import Undo from 'lucide-react-native/icons/undo-2';
import User from 'lucide-react-native/icons/user';
import Volume from 'lucide-react-native/icons/volume-2';
import WifiOff from 'lucide-react-native/icons/wifi-off';
import X from 'lucide-react-native/icons/x';
// Added by M6 (settings, models, first run).
import Bell from 'lucide-react-native/icons/bell';
import Brain from 'lucide-react-native/icons/brain';
import CircleCheck from 'lucide-react-native/icons/circle-check';
import Database from 'lucide-react-native/icons/database';
import Download from 'lucide-react-native/icons/download';
import ExternalLink from 'lucide-react-native/icons/external-link';
import HardDrive from 'lucide-react-native/icons/hard-drive';
import Languages from 'lucide-react-native/icons/languages';
import LockKeyholeOpen from 'lucide-react-native/icons/lock-keyhole-open';
import Pause from 'lucide-react-native/icons/pause';
import Play from 'lucide-react-native/icons/play';
import ShieldCheck from 'lucide-react-native/icons/shield-check';
import SlidersHorizontal from 'lucide-react-native/icons/sliders-horizontal';
import Smartphone from 'lucide-react-native/icons/smartphone';
import TriangleAlert from 'lucide-react-native/icons/triangle-alert';
import Upload from 'lucide-react-native/icons/upload';
import UserRound from 'lucide-react-native/icons/user-round';
import Vibrate from 'lucide-react-native/icons/vibrate';
import Wifi from 'lucide-react-native/icons/wifi';
import Zap from 'lucide-react-native/icons/zap';

export interface GlyphProps {
  size?: number;
  color?: string;
  strokeWidth?: number;
}

/** Two lines, the lower one shorter: the drawer button. */
function MenuGlyph({size = 24, color = '#000', strokeWidth = 2}: GlyphProps) {
  return (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <Path
        d="M4 8.5h16M4 15.5h10"
        stroke={color}
        strokeWidth={strokeWidth}
        strokeLinecap="round"
      />
    </Svg>
  );
}

/** A filled, rounded square: stop. Drawn solid so it reads at 12 px. */
function StopGlyph({size = 24, color = '#000'}: GlyphProps) {
  return (
    <Svg width={size} height={size} viewBox="0 0 24 24">
      <Path
        d="M8 4.5h8A3.5 3.5 0 0 1 19.5 8v8a3.5 3.5 0 0 1-3.5 3.5H8A3.5 3.5 0 0 1 4.5 16V8A3.5 3.5 0 0 1 8 4.5Z"
        fill={color}
      />
    </Svg>
  );
}

/** The GitHub mark (lucide ships no brand icons). Filled, like the original. */
function GitHubGlyph({size = 24, color = '#000'}: GlyphProps) {
  return (
    <Svg width={size} height={size} viewBox="0 0 24 24">
      <Path
        d="M12 1.5C6.2 1.5 1.5 6.2 1.5 12c0 4.64 3.01 8.58 7.18 9.97.53.1.72-.23.72-.5v-1.77c-2.92.63-3.54-1.41-3.54-1.41-.48-1.21-1.17-1.54-1.17-1.54-.95-.65.07-.64.07-.64 1.06.07 1.61 1.09 1.61 1.09.94 1.6 2.46 1.14 3.06.87.1-.68.37-1.14.66-1.4-2.33-.27-4.78-1.17-4.78-5.19 0-1.15.41-2.08 1.08-2.82-.11-.27-.47-1.33.1-2.78 0 0 .88-.28 2.89 1.08a10 10 0 0 1 5.26 0c2-1.36 2.88-1.08 2.88-1.08.57 1.45.21 2.51.1 2.78.67.74 1.08 1.67 1.08 2.82 0 4.03-2.46 4.92-4.8 5.18.38.33.71.97.71 1.96v2.9c0 .28.19.61.73.5A10.5 10.5 0 0 0 22.5 12C22.5 6.2 17.8 1.5 12 1.5Z"
        fill={color}
      />
    </Svg>
  );
}

/** The same glyph filled in: a rating that is set. */
function filled(Glyph: ComponentType<GlyphProps & {fill?: string}>) {
  return function Filled({size, color, strokeWidth}: GlyphProps) {
    return (
      <Glyph size={size} color={color} strokeWidth={strokeWidth} fill={color} />
    );
  };
}

export const glyphs = {
  menu: MenuGlyph,
  newChat: SquarePen,
  more: Ellipsis,
  add: Plus,
  apps: LayoutGrid,
  mic: Mic,
  voice: AudioLines,
  send: ArrowUp,
  stop: StopGlyph,
  square: Square,
  arrowDown: ArrowDown,
  thumbsUp: ThumbsUp,
  thumbsDown: ThumbsDown,
  thumbsUpFilled: filled(ThumbsUp),
  thumbsDownFilled: filled(ThumbsDown),
  branch: GitBranch,
  selectText: TextSelect,
  temporary: MessageCircleDashed,
  quote: Reply,
  document: FileText,
  paste: ClipboardGlyph,
  research: Telescope,
  study: GraduationCap,
  calculator: Calculator,
  search: Search,
  settings: Settings,
  close: X,
  check: Check,
  chevronDown: ChevronDown,
  /** Points "forward"; mirrored in right-to-left layouts by `Icon`. */
  chevronForward: ChevronRight,
  /** Points "back"; mirrored in right-to-left layouts by `Icon`. */
  chevronBack: ChevronLeft,
  pin: Pin,
  unpin: PinOff,
  rename: Pencil,
  archive: Archive,
  delete: Trash,
  copy: Copy,
  share: Share,
  retry: RefreshCw,
  alert: CircleAlert,
  info: Info,
  offline: WifiOff,
  location: MapPin,
  appearance: Palette,
  image: Image,
  folder: Folder,
  attach: Paperclip,
  camera: Camera,
  web: Globe,
  think: Lightbulb,
  readAloud: Volume,
  sparkles: Sparkles,
  // ANTICHAT M4: history UI glyphs.
  lock: Lock,
  unlock: LockOpen,
  unarchive: ArchiveRestore,
  undo: Undo,
  user: User,
  recent: Clock,
  plainText: LetterText,
  json: Braces,
  // M6: settings, models, first run.
  pause: Pause,
  play: Play,
  download: Download,
  upload: Upload,
  person: UserRound,
  storage: HardDrive,
  phone: Smartphone,
  privacy: ShieldCheck,
  advanced: SlidersHorizontal,
  language: Languages,
  data: Database,
  external: ExternalLink,
  wifi: Wifi,
  unrestricted: LockKeyholeOpen,
  haptics: Vibrate,
  memory: Brain,
  fast: Zap,
  success: CircleCheck,
  warning: TriangleAlert,
  bell: Bell,
  github: GitHubGlyph,
  support: LifeBuoy,
} satisfies Record<string, ComponentType<GlyphProps>>;

export type IconName = keyof typeof glyphs;

/** Glyphs that point along the reading direction. */
export const DIRECTIONAL: ReadonlySet<IconName> = new Set([
  'chevronForward',
  'chevronBack',
]);

/**
 * SF Symbol names for native menus on iOS (the only place system icons are
 * used; Android menus show titles only).
 */
export const SF_SYMBOLS: Partial<Record<IconName, string>> = {
  newChat: 'square.and.pencil',
  pin: 'pin',
  unpin: 'pin.slash',
  rename: 'pencil',
  archive: 'archivebox',
  delete: 'trash',
  copy: 'doc.on.doc',
  share: 'square.and.arrow.up',
  retry: 'arrow.clockwise',
  check: 'checkmark',
  settings: 'gearshape',
  info: 'info.circle',
  appearance: 'paintpalette',
  think: 'lightbulb',
  web: 'globe',
  sparkles: 'sparkles',
  thumbsUp: 'hand.thumbsup',
  thumbsDown: 'hand.thumbsdown',
  thumbsUpFilled: 'hand.thumbsup.fill',
  thumbsDownFilled: 'hand.thumbsdown.fill',
  branch: 'arrow.triangle.branch',
  selectText: 'text.cursor',
  readAloud: 'speaker.wave.2',
  quote: 'arrowshape.turn.up.left',
  image: 'photo',
  camera: 'camera',
  attach: 'paperclip',
  document: 'doc.text',
  folder: 'folder',
  stop: 'stop.fill',
  lock: 'lock',
  unlock: 'lock.open',
  temporary: 'bubble.left.and.text.bubble.right',
  offline: 'wifi.slash',
  location: 'location',
  unarchive: 'arrow.up.bin',
  undo: 'arrow.uturn.backward',
};
