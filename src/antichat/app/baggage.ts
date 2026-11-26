/**
 * Switches off the parts of PocketPal that AntiChat does not have, without
 * deleting upstream code (docs/research/04-gap-analysis.md §3).
 *
 * What makes the baggage unreachable:
 * - Upstream's navigator is not mounted, so Pals, Benchmark, Models, the
 *   six-step onboarding, Plus and Dev Tools have no entry point.
 * - The effects in upstream's `App` (purchases, TTS/ASR setup sheets) never
 *   run, because that component is not rendered.
 * - Firebase App Check is only initialised by the benchmark and feedback
 *   uploads, which nothing calls. The native launch call is removed in
 *   `ios/PocketPal/AppDelegate.swift`.
 * - `.env`: ENABLE_PALSHUB_INTEGRATION=false, ENABLE_AUTHENTICATION=false.
 *
 * What is left is upstream stores raising blocking alerts on their own
 * (download errors, memory warnings). Those are captured here; AntiChat shows
 * problems inline, through typed state on the ports.
 */
import {Alert} from 'react-native';

export interface SuppressedAlert {
  title: string;
  message?: string;
  at: number;
}

const MAX_KEPT = 50;
const suppressed: SuppressedAlert[] = [];
let originalAlert: typeof Alert.alert | undefined;

/** Alerts upstream tried to show, newest last. For logs and tests. */
export function suppressedAlerts(): readonly SuppressedAlert[] {
  return suppressed;
}

export function switchOffUpstreamBaggage(): void {
  if (originalAlert) {
    return;
  }
  originalAlert = Alert.alert;
  Alert.alert = (title, message) => {
    suppressed.push({
      title: title ?? '',
      message: message ?? undefined,
      at: Date.now(),
    });
    if (suppressed.length > MAX_KEPT) {
      suppressed.shift();
    }
    if (__DEV__) {
      console.log(`[antichat] upstream alert suppressed: ${title}`);
    }
  };
}

/** Puts the alert back (tests, and the switch to upstream's UI). */
export function restoreUpstreamBaggage(): void {
  if (originalAlert) {
    Alert.alert = originalAlert;
    originalAlert = undefined;
  }
  suppressed.length = 0;
}
