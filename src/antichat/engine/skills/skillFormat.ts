/**
 * Skills as data. A skill is `{name, description, body}`: only name and
 * description are ever listed to the model, the body is loaded when the skill
 * is active. The built-in ones ship as JSON (Metro bundles JSON without
 * config changes); `parseSkillMarkdown` reads the SKILL.md form (front matter
 * + body, the AI Edge Gallery / AntiChat Mac format) for skills added later.
 */

export interface Skill {
  name: string;
  description: string;
  body: string;
}

/** Parse a SKILL.md document. Returns null when name or body is missing. */
export function parseSkillMarkdown(source: string): Skill | null {
  const match = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/.exec(
    source.trimStart(),
  );
  if (!match) {
    return null;
  }
  const meta: Record<string, string> = {};
  for (const line of match[1].split(/\r?\n/)) {
    const pair = /^([A-Za-z_-]+)\s*:\s*(.*)$/.exec(line);
    if (pair) {
      meta[pair[1].toLowerCase()] = pair[2].trim().replace(/^["']|["']$/g, '');
    }
  }
  const body = match[2].trim();
  if (!meta.name || !body) {
    return null;
  }
  return {name: meta.name, description: meta.description ?? '', body};
}

const oneLine = (text: string): string =>
  text
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(Boolean)
    .join(' ');

/** Name-and-description manifest (Mac `SkillManifestBlock`), sorted by name. */
export function renderSkillManifest(skills: readonly Skill[]): string {
  if (!skills.length) {
    return '';
  }
  const lines = [...skills]
    .sort((a, b) => a.name.localeCompare(b.name))
    .map(skill => `${skill.name}: ${oneLine(skill.description)}`);
  return ['<available_skills>', ...lines, '</available_skills>'].join('\n');
}
