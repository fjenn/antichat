import {useT} from '../../locales';
import {useChatReady, useSetupStatus} from '../models';
import {composerHint} from './wording';

export interface ComposerReadiness {
  /** A model is loaded: sending works. */
  ready: boolean;
  /** Replaces the composer's placeholder while not ready. */
  placeholder: string | null;
}

/**
 * What the composer shows while the assistant is not usable yet. The chat
 * screen is reachable from the first second; the composer says when it will
 * answer.
 */
export function useComposerReadiness(): ComposerReadiness {
  const t = useT();
  const status = useSetupStatus();
  const ready = useChatReady();
  const hint = composerHint(status, ready);
  return {ready, placeholder: hint ? t(hint) : null};
}
