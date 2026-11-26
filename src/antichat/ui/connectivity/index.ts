/**
 * Offline behaviour as reusable pieces, fed by the connectivity port: the
 * top-bar pill, the "needs a connection" wrapper for online-only controls and
 * the one-line note under an answer that wanted to search.
 */
export {OfflinePill, type OfflinePillProps} from './OfflinePill';
export {
  NeedsConnection,
  OfflineAnswerNote,
  type NeedsConnectionProps,
  type OfflineAnswerNoteProps,
} from './NeedsConnection';
export {useMetered, useOnline} from './useConnectivity';
