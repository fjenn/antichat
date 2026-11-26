import React, {useRef} from 'react';

import type {ModelView} from '../../contracts';
import {useT} from '../../locales';
import {haptics, type MenuItem, type SheetHandle} from '../primitives';
import {ConfirmSheet} from '../settings/components';
import {formatBytes, formatPercent} from './format';
import {useModels} from './hooks';
import {isArriving, isInstalled, unrestrictedPair} from './naming';
import {modelCoordinator} from './shared';
import {ms} from './strings';

export {unrestrictedPair};
export const UNRESTRICTED_ITEM = 'mode:unrestricted';

export interface UnrestrictedMode {
  /** Unrestricted model in use (the top bar marks it). */
  on: boolean;
  /** The menu's switch; absent when the model in use has no counterpart. */
  item?: MenuItem;
  /** Handles the switch's id; false for any other id. */
  select: (id: string) => boolean;
  /** The one-tap download offer; render it once beside the menu. */
  sheet: React.ReactElement;
}

/**
 * "Unrestricted" as a mode of the model in use: one switch in the top-bar
 * menu swaps to the unrestricted model of the same size and back. If that
 * model is not on the phone yet, one sheet offers the download (with the 18+
 * confirmation the first time); AntiChat switches once it is ready.
 */
export function useUnrestrictedMode(): UnrestrictedMode {
  const t = useT();
  const {port, activeModelId} = useModels();
  const coordinator = modelCoordinator();
  const {prefs} = coordinator;
  const offer = useRef<SheetHandle>(null);
  const pair = unrestrictedPair(port.models, activeModelId);
  const target = pair?.target;
  const consented = prefs.unrestrictedConsentAt !== null;

  let item: MenuItem | undefined;
  if (pair && target) {
    const arriving = isArriving(target);
    const progress =
      target.state.status === 'downloading'
        ? formatPercent(target.state.progress.fraction)
        : null;
    item = {
      id: UNRESTRICTED_ITEM,
      title: ms.unrestricted,
      subtitle: pair.on
        ? ms.unrestrictedOnHint
        : arriving
          ? ms.unrestrictedArriving(progress)
          : isInstalled(target)
            ? ms.unrestrictedOffHint
            : ms.unrestrictedDownloadHint(formatBytes(target.downloadBytes)),
      icon: 'unlock',
      checked: pair.on,
    };
  }

  const backToStandard = (base: ModelView) => {
    if (isInstalled(base)) {
      coordinator.choose(base.recommended ? 'auto' : base.id);
      return;
    }
    // The standard model of this size is not on the phone: use any that is,
    // rather than start a download to leave the mode.
    const fallback =
      port.models.find(
        model => !model.unrestricted && model.recommended && isInstalled(model),
      ) ??
      port.models.find(
        model => !model.unrestricted && model.supported && isInstalled(model),
      );
    coordinator.choose(
      fallback ? (fallback.recommended ? 'auto' : fallback.id) : base.id,
    );
  };

  const select = (id: string): boolean => {
    if (id !== UNRESTRICTED_ITEM || !pair || !target) {
      return false;
    }
    haptics.selection();
    if (pair.on) {
      backToStandard(target);
    } else if (isInstalled(target)) {
      coordinator.choose(target.id);
    } else if (!isArriving(target)) {
      offer.current?.present().catch(() => {});
    }
    return true;
  };

  const size = formatBytes(target?.downloadBytes ?? 0);
  const sheet = (
    <ConfirmSheet
      ref={offer}
      testID="unrestricted-offer"
      title={consented ? ms.offerTitle : t('models.unrestricted.consentTitle')}
      message={
        consented
          ? ms.offerMessage(size)
          : `${t('models.unrestricted.consentMessage')} ${ms.offerSwitchNote}`
      }
      confirmLabel={
        consented
          ? ms.offerConfirm(size)
          : t('models.unrestricted.consentConfirm', {size})
      }
      cancelLabel={t('models.unrestricted.consentCancel')}
      onConfirm={() => {
        if (!target) {
          return;
        }
        if (!consented) {
          prefs.set({unrestrictedConsentAt: Date.now()});
        }
        // Downloads it; the chat keeps the current model until it is ready.
        coordinator.choose(target.id);
      }}
    />
  );

  return {on: pair?.on ?? false, item, select, sheet};
}
