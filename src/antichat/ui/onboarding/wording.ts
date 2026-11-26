/**
 * Words for the first-run card and the composer, from a `SetupStatus`. Kept
 * apart from the card so the wording has its own tests.
 */
import type {MessageKey, Translate} from '../../locales';
import {
  durationParts,
  formatBytes,
  formatProgressBytes,
  type SetupStatus,
} from '../models';

export interface SetupWording {
  title: string;
  line: string;
  /** 0..1 when a bar is shown; null = shown without a known amount. */
  fraction?: number | null;
  /** The bar is not moving (paused, waiting). */
  idle?: boolean;
  tone: 'neutral' | 'success' | 'problem';
}

export function timeLeft(t: Translate, seconds: number | undefined): string {
  const parts = durationParts(seconds);
  if (!parts) {
    return '';
  }
  switch (parts.unit) {
    case 'moment':
      return t('setup.left.moment');
    case 'seconds':
      return t('setup.left.seconds', {value: parts.value});
    case 'minutes':
      return parts.value === 1
        ? t('setup.left.minute')
        : t('setup.left.minutes', {value: parts.value});
    case 'hours':
      return parts.value === 1
        ? t('setup.left.hour')
        : t('setup.left.hours', {value: parts.value});
  }
}

const join = (...parts: string[]): string => parts.filter(Boolean).join(' · ');

export function setupWording(t: Translate, status: SetupStatus): SetupWording {
  switch (status.kind) {
    case 'hidden':
      return {title: '', line: '', tone: 'neutral'};
    case 'preparing':
      return {
        title: t('setup.preparing'),
        line: t('setup.preparingLine'),
        fraction: null,
        tone: 'neutral',
      };
    case 'downloading':
      return {
        title: t('setup.downloading'),
        line: join(
          formatProgressBytes(status.receivedBytes, status.totalBytes),
          timeLeft(t, status.etaSeconds),
        ),
        fraction: status.fraction,
        tone: 'neutral',
      };
    case 'paused': {
      const progress = formatProgressBytes(
        status.receivedBytes,
        status.totalBytes,
      );
      if (status.reason === 'offline') {
        return {
          title: t('setup.pausedOffline'),
          line: t('setup.pausedOfflineLine', {progress}),
          fraction: status.fraction,
          idle: true,
          tone: 'neutral',
        };
      }
      return {
        title:
          status.reason === 'metered'
            ? t('setup.pausedMetered')
            : t('setup.paused'),
        line: progress,
        fraction: status.fraction,
        idle: true,
        tone: 'neutral',
      };
    }
    case 'confirm_metered':
      return {
        title: t('setup.confirmMetered'),
        line: t('setup.confirmMeteredLine', {size: formatBytes(status.bytes)}),
        tone: 'neutral',
      };
    case 'waiting_wifi':
      return {
        title: t('setup.waitingWifi'),
        line: t('setup.waitingWifiLine', {size: formatBytes(status.bytes)}),
        tone: 'neutral',
      };
    case 'verifying':
      return {
        title: t('setup.verifying'),
        line: t('setup.verifyingLine'),
        fraction: status.fraction,
        tone: 'neutral',
      };
    case 'loading':
      return {
        title: t('setup.loading'),
        line: t('setup.loadingLine'),
        fraction: null,
        tone: 'neutral',
      };
    case 'ready':
      return {
        title: t('setup.ready'),
        line: t('setup.readyLine'),
        tone: 'success',
      };
    case 'missing':
      return {
        title: t('setup.missing'),
        line: t('setup.missingLine', {size: formatBytes(status.bytes)}),
        tone: 'neutral',
      };
    case 'failed':
      return {...failureWording(t, status), tone: 'problem'};
  }
}

function failureWording(
  t: Translate,
  status: Extract<SetupStatus, {kind: 'failed'}>,
): {title: string; line: string} {
  switch (status.reason) {
    case 'storage_full':
      return {
        title: t('setup.failed.storageTitle'),
        line: status.neededBytes
          ? t('setup.failed.storageLine', {
              size: formatBytes(status.neededBytes),
            })
          : t('setup.failed.storageLineUnknown'),
      };
    case 'offline':
      return {
        title: t('setup.failed.offlineTitle'),
        line: t('setup.failed.offlineLine'),
      };
    case 'checksum_mismatch':
    case 'file_missing':
      return {
        title: t('setup.failed.checksumTitle'),
        line: t('setup.failed.checksumLine'),
      };
    case 'out_of_memory':
      return {
        title: t('setup.failed.loadTitle'),
        line: t('setup.failed.memoryLine'),
      };
    case 'load_failed':
      return {
        title: t('setup.failed.loadTitle'),
        line: t('setup.failed.loadLine'),
      };
    case 'download_failed':
      return {
        title: t('setup.failed.downloadTitle'),
        line: t('setup.failed.downloadLine'),
      };
  }
}

/** What the composer says instead of its usual placeholder; null when ready. */
export function composerHint(
  status: SetupStatus,
  chatReady: boolean,
): MessageKey | null {
  if (chatReady) {
    return null;
  }
  switch (status.kind) {
    case 'downloading':
    case 'verifying':
    case 'preparing':
      return 'setup.composer.downloading';
    case 'paused':
      return status.reason === 'user'
        ? 'setup.composer.paused'
        : 'setup.composer.waiting';
    case 'confirm_metered':
    case 'waiting_wifi':
      return 'setup.composer.waiting';
    case 'loading':
    case 'ready':
      return 'setup.composer.starting';
    case 'failed':
    case 'missing':
      return 'setup.composer.missing';
    case 'hidden':
      return 'setup.composer.starting';
  }
}
