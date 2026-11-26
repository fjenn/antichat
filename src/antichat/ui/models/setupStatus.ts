/**
 * The one thing the first-run card says, worked out from the engine's typed
 * state. Pure, so every case has a test and the card only draws.
 */
import type {
  FailureReason,
  ModelNotice,
  ModelState,
  PauseReason,
} from '../../contracts';

export type SetupStatus =
  /** Nothing to show: a model is loaded and the moment has passed. */
  | {kind: 'hidden'}
  /** Looking at the phone, or about to start. */
  | {kind: 'preparing'}
  | {
      kind: 'downloading';
      fraction: number;
      receivedBytes: number;
      totalBytes: number;
      etaSeconds?: number;
    }
  | {
      kind: 'paused';
      reason: PauseReason;
      fraction: number;
      receivedBytes: number;
      totalBytes: number;
    }
  /** On mobile data: one question, with the size. */
  | {kind: 'confirm_metered'; noticeId: string; bytes: number}
  | {kind: 'waiting_wifi'; bytes: number}
  | {kind: 'verifying'; fraction: number}
  | {kind: 'loading'}
  /** The completion moment. */
  | {kind: 'ready'}
  | {
      kind: 'failed';
      reason: FailureReason;
      retryable: boolean;
      /** Bytes the download needs, when storage was the problem. */
      neededBytes?: number;
    }
  /** Started before, but no model is on the phone any more. */
  | {kind: 'missing'; bytes: number};

export interface SetupInput {
  started: boolean;
  enginePhase: 'idle' | 'initializing' | 'ready';
  /** The model first run is about (the automatic choice, or the user's). */
  targetId: string | null;
  targetBytes: number;
  state: ModelState;
  activeModelId: string | null;
  /** State of the active model when it is not the target. */
  activeState?: ModelState;
  notices: readonly ModelNotice[];
  waitForWifi: boolean;
  /** The ready moment has not been shown yet. */
  celebrate: boolean;
  /** Free space on the phone when it was last read. */
  freeBytes?: number;
}

export function setupStatus(input: SetupInput): SetupStatus {
  if (!input.started) {
    return {kind: 'hidden'};
  }
  if (input.enginePhase !== 'ready' || input.targetId === null) {
    return {kind: 'preparing'};
  }
  // Another model is in use (the user picked one by hand, or a fallback).
  if (
    input.activeModelId !== null &&
    input.activeModelId !== input.targetId &&
    input.activeState
  ) {
    if (input.activeState.status === 'loaded') {
      return input.celebrate ? {kind: 'ready'} : {kind: 'hidden'};
    }
    if (input.activeState.status === 'loading') {
      return {kind: 'loading'};
    }
  }

  const {state} = input;
  switch (state.status) {
    case 'loaded':
      return input.celebrate ? {kind: 'ready'} : {kind: 'hidden'};
    case 'loading':
      return {kind: 'loading'};
    case 'ready':
      // Installed and about to be loaded by the coordinator.
      return {kind: 'loading'};
    case 'verifying':
      return {kind: 'verifying', fraction: state.fraction};
    case 'downloading': {
      const {progress} = state;
      if (state.paused) {
        return {
          kind: 'paused',
          reason: state.pauseReason ?? 'user',
          fraction: progress.fraction,
          receivedBytes: progress.receivedBytes,
          totalBytes: progress.totalBytes,
        };
      }
      return {
        kind: 'downloading',
        fraction: progress.fraction,
        receivedBytes: progress.receivedBytes,
        totalBytes: progress.totalBytes,
        etaSeconds: progress.etaSeconds,
      };
    }
    case 'failed': {
      const storage = input.notices.find(
        notice => notice.kind === 'storage_limited',
      );
      return {
        kind: 'failed',
        reason: state.reason,
        retryable: state.retryable,
        neededBytes:
          state.reason === 'storage_full'
            ? storage?.kind === 'storage_limited'
              ? Math.max(0, storage.neededBytes - storage.freeBytes)
              : spaceToFree(input.targetBytes, input.freeBytes)
            : undefined,
      };
    }
    case 'not_installed': {
      const metered = input.notices.find(
        notice =>
          notice.kind === 'confirm_metered' &&
          notice.modelId === input.targetId,
      );
      if (metered?.kind === 'confirm_metered') {
        return {
          kind: 'confirm_metered',
          noticeId: metered.id,
          bytes: metered.bytes,
        };
      }
      if (input.waitForWifi) {
        return {kind: 'waiting_wifi', bytes: input.targetBytes};
      }
      return {kind: 'missing', bytes: input.targetBytes};
    }
  }
}

/**
 * How much to free for a download: its size plus the engine's safety margin
 * (the larger of 500 MB and a tenth), less what is free already.
 */
export function spaceToFree(bytes: number, freeBytes?: number): number {
  const needed = bytes + Math.max(524_288_000, bytes * 0.1);
  return freeBytes === undefined
    ? bytes
    : Math.max(bytes * 0.05, needed - freeBytes);
}

/** The composer can send: some model is loaded. */
export function isChatReady(
  activeModelId: string | null,
  activeState: ModelState | undefined,
): boolean {
  return activeModelId !== null && activeState?.status === 'loaded';
}
