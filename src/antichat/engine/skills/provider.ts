/**
 * Request provider for skills: the crisis rule (always), the study-mode
 * addendum (per chat) and the voice addendum (spoken replies).
 *
 * All three are stable blocks: the crisis rule never changes, and study mode
 * and voice are fixed for the life of a chat or a voice session, so none of
 * them disturbs the cached prefix from turn to turn.
 */
import {messageText} from '../context/tokenCounter';
import type {Contribution, RequestProvider, SystemBlock} from '../prompt/types';
import {
  countryFromLocale,
  detectCrisis,
  helplineContextLine,
  helplineFor,
} from './crisis';
import {CRISIS, STUDY_MODE, VOICE_MODE, getSkill} from './registry';

export const SKILLS_PROVIDER_ID = 'antichat.skills';
const CRISIS_MEMORY_TURNS = 3;

export function createSkillsProvider(): RequestProvider {
  return {
    id: SKILLS_PROVIDER_ID,
    order: 20,
    contribute: ({session, messages}): Contribution => {
      const systemBlocks: SystemBlock[] = [];
      const add = (name: string, order: number) => {
        const skill = getSkill(name);
        if (skill) {
          systemBlocks.push({
            id: `skill.${name}`,
            slot: 'stable',
            order,
            text: skill.body,
          });
        }
      };
      if (session.studyMode) {
        add(STUDY_MODE, 60);
      }
      if (session.spoken) {
        add(VOICE_MODE, 65);
      }
      // The instruction stays for a few turns after a crisis message: the
      // follow-up ("ok, who can I call?") rarely repeats the signal.
      const recentUserTexts = messages
        .filter(message => message.role === 'user')
        .slice(-CRISIS_MEMORY_TURNS)
        .map(message => messageText(message).text);
      if (!recentUserTexts.some(detectCrisis)) {
        return {systemBlocks};
      }
      // Only now: with the rule always in the prompt, LFM3 1.7B appended a
      // helpline to ordinary answers (seen in the merged app, 2026-11-24).
      // The prompt prefix changes for these chats only.
      add(CRISIS, 25);
      const country =
        session.countryCode ?? countryFromLocale(session.locale) ?? undefined;
      return {
        systemBlocks,
        turnContext: [helplineContextLine(country)],
        meta: {crisis: {countryCode: country, helpline: helplineFor(country)}},
      };
    },
  };
}
