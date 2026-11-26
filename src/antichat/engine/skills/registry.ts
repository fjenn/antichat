/** The skill catalogue: built-in data files plus skills registered later. */
import crisis from './data/crisis.json';
import studyMode from './data/study-mode.json';
import voiceMode from './data/voice-mode.json';
import type {Skill} from './skillFormat';

export const STUDY_MODE = 'study-mode';
export const VOICE_MODE = 'voice-mode';
export const CRISIS = 'crisis';

const skills = new Map<string, Skill>(
  [studyMode, voiceMode, crisis].map(skill => [skill.name, skill as Skill]),
);

export function getSkill(name: string): Skill | undefined {
  return skills.get(name);
}

export function listSkills(): Skill[] {
  return [...skills.values()];
}

export function registerSkill(skill: Skill): void {
  skills.set(skill.name, skill);
}
