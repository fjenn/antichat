/**
 * Voice mode as a state machine. Pure: the controller feeds it events and
 * acts on the transitions; an event that is not legal in a state is ignored.
 *
 *   off → starting → listening → thinking → speaking → listening …
 *
 * - `listening`: microphone open, waiting for the end of the user's turn.
 * - `thinking`: turn captured; transcript, model and first sentence under way.
 * - `speaking`: answer audio is playing; the microphone stays open for barge-in.
 * - `paused`: a call or another app holds the audio.
 */

export type VoicePhase =
  | 'off'
  | 'starting'
  | 'listening'
  | 'thinking'
  | 'speaking'
  | 'paused';

export type VoiceMachineEvent =
  | 'START'
  /** Session, models and microphone are up. */
  | 'READY'
  /** The user's turn ended with speech in it. */
  | 'TURN_ENDED'
  /** Nothing usable was heard, or the turn failed in a recoverable way. */
  | 'TURN_DROPPED'
  | 'FIRST_AUDIO'
  /** The answer was spoken to the end (or had nothing to say). */
  | 'REPLY_DONE'
  /** The user spoke or tapped during thinking or speaking. */
  | 'BARGE_IN'
  | 'INTERRUPTION_BEGAN'
  | 'INTERRUPTION_ENDED'
  | 'STOP';

const TABLE: Record<
  VoicePhase,
  Partial<Record<VoiceMachineEvent, VoicePhase>>
> = {
  off: {START: 'starting'},
  starting: {READY: 'listening', STOP: 'off'},
  listening: {
    TURN_ENDED: 'thinking',
    TURN_DROPPED: 'listening',
    INTERRUPTION_BEGAN: 'paused',
    STOP: 'off',
  },
  thinking: {
    FIRST_AUDIO: 'speaking',
    REPLY_DONE: 'listening',
    TURN_DROPPED: 'listening',
    BARGE_IN: 'listening',
    INTERRUPTION_BEGAN: 'paused',
    STOP: 'off',
  },
  speaking: {
    REPLY_DONE: 'listening',
    TURN_DROPPED: 'listening',
    BARGE_IN: 'listening',
    INTERRUPTION_BEGAN: 'paused',
    STOP: 'off',
  },
  paused: {INTERRUPTION_ENDED: 'listening', STOP: 'off'},
};

/** The next phase, or null when the event does not apply. */
export const transition = (
  phase: VoicePhase,
  event: VoiceMachineEvent,
): VoicePhase | null => TABLE[phase][event] ?? null;
