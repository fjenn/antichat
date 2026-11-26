/**
 * Connectivity: the one flag online tools, downloads and the offline hint
 * read. M5 implements it on NetInfo.
 */
import type {Observable} from './common';

export interface Connectivity extends Observable {
  /** The internet is reachable. */
  readonly online: boolean;
  /** On cellular or another metered link: ask before large downloads. */
  readonly metered: boolean;
  /** Ask the OS again (after the user taps "Try again"). */
  refresh(): Promise<void>;
}
