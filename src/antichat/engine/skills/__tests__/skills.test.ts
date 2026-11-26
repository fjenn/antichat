import helplines from '../data/helplines.json';
import {
  clearRequestProviders,
  prepareRequest,
  registerRequestProvider,
} from '../../prompt/registry';
import {estimateTokens} from '../../context/tokenCounter';
import {
  CRISIS,
  STUDY_MODE,
  VOICE_MODE,
  countryFromLocale,
  createSkillsProvider,
  detectCrisis,
  getSkill,
  helplineContextLine,
  helplineFor,
  listHelplines,
  listSkills,
  removeUnverifiedNumbers,
  unverifiedNumbers,
  parseSkillMarkdown,
  registerSkill,
  renderSkillManifest,
} from '..';

describe('skills as data', () => {
  it('ships study mode, the voice addendum and the crisis rule', () => {
    expect(
      listSkills()
        .map(s => s.name)
        .sort(),
    ).toEqual([CRISIS, STUDY_MODE, VOICE_MODE].sort());
    for (const skill of listSkills()) {
      expect(skill.description.length).toBeGreaterThan(10);
      expect(estimateTokens(skill.body)).toBeLessThan(160);
    }
    expect(getSkill(VOICE_MODE)?.body).toContain('spoken aloud');
    expect(getSkill(STUDY_MODE)?.body).toContain('one guiding question');
  });

  it('parses the SKILL.md form and registers it', () => {
    const skill = parseSkillMarkdown(
      '---\nname: recipe-helper\ndescription: "Scales recipes."\n---\n\nAlways give metric units.\n',
    );
    expect(skill).toEqual({
      name: 'recipe-helper',
      description: 'Scales recipes.',
      body: 'Always give metric units.',
    });
    expect(parseSkillMarkdown('no front matter')).toBeNull();
    expect(parseSkillMarkdown('---\ndescription: x\n---\nbody')).toBeNull();
    registerSkill(skill!);
    expect(getSkill('recipe-helper')).toBe(skill);
  });

  it('renders a name-and-description manifest, sorted', () => {
    expect(
      renderSkillManifest([
        {name: 'b', description: 'Second\nline', body: ''},
        {name: 'a', description: 'First', body: ''},
      ]),
    ).toBe('<available_skills>\na: First\nb: Second line\n</available_skills>');
    expect(renderSkillManifest([])).toBe('');
  });
});

describe('helpline table', () => {
  it('has a checked date and well-formed rows', () => {
    expect(helplines.checked).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    const rows = listHelplines();
    expect(rows.length).toBeGreaterThanOrEqual(40);
    for (const row of rows) {
      expect(row.countryCode).toMatch(/^[A-Z]{2}$/);
      expect(row.emergency).toMatch(/^[\d ]{2,5}$/);
      if (row.name) {
        expect(row.phone).toMatch(/^[\d *+()/a-z-]{3,}$/);
      } else {
        expect(row.phone).toBeUndefined();
      }
    }
  });

  it('looks countries up, case-insensitively', () => {
    expect(helplineFor('us')).toMatchObject({
      name: '988 Suicide & Crisis Lifeline',
      phone: '988',
      emergency: '911',
    });
    expect(helplineFor('DE')?.phone).toBe('0800 111 0 111');
    expect(helplineFor('GB')?.phone).toBe('116 123');
    expect(helplineFor('ZZ')).toBeNull();
    expect(helplineFor(undefined)).toBeNull();
  });

  it('does not list a service where none is confirmed', () => {
    for (const code of ['TR', 'RU', 'UA']) {
      expect(helplineFor(code)).toEqual({countryCode: code, emergency: '112'});
    }
  });

  it('derives the country from a locale', () => {
    expect(countryFromLocale('de-AT')).toBe('AT');
    expect(countryFromLocale('en_US')).toBe('US');
    expect(countryFromLocale('zh-Hans-CN')).toBe('CN');
    expect(countryFromLocale('en')).toBeUndefined();
    expect(countryFromLocale(undefined)).toBeUndefined();
  });

  it('builds the instruction for the model only from the table', () => {
    expect(helplineContextLine('AU')).toBe(
      'Instruction: the user may be in crisis. The ONLY helpline you may give is this verified one for where the user is: Lifeline, phone 13 11 14, text 0477 13 11 14 (open 24/7). Emergency number: 000. Do not give any other phone number and do not mention other countries.',
    );
    expect(helplineContextLine('TR')).toContain('emergency number (112)');
    expect(helplineContextLine(undefined)).toContain('findahelpline.com');
    expect(helplineContextLine(undefined)).not.toMatch(/phone \d/);
  });

  it('finds and removes numbers the table does not know', () => {
    const reply =
      'I am so sorry you feel this way. You can call or text 988 anytime in the US and Canada. In the UK, you can call 111. Samaritans are there on 116 123, free and 24/7. If you are in danger, call 999.';
    expect(unverifiedNumbers(reply, 'GB')).toEqual(['988', '111']);
    expect(removeUnverifiedNumbers(reply, 'GB')).toEqual({
      text: 'I am so sorry you feel this way. Samaritans are there on 116 123, free and 24/7. If you are in danger, call 999.',
      removed: ['988', '111'],
    });
    const fine = 'Please call 0800 111 0 111 or 112. You matter.';
    expect(removeUnverifiedNumbers(fine, 'DE')).toEqual({
      text: fine,
      removed: [],
    });
    expect(unverifiedNumbers('Call 1-800-273-8255 now', undefined)).toEqual([
      '1-800-273-8255',
    ]);
    expect(
      unverifiedNumbers('Text 0477 13 11 14 or call 13 11 14', 'AU'),
    ).toEqual([]);
  });
});

describe('crisis detection', () => {
  it.each([
    'I want to kill myself',
    "I don't want to live anymore",
    'I do not want to live anymore.',
    'i dont want to be here any more',
    'I no longer want to live',
    'sometimes i think about suicide',
    'Ich will nicht mehr leben',
    'quiero morir',
    "j'ai envie de mourir",
    '死にたい',
    'я хочу умереть',
  ])('flags %j', text => {
    expect(detectCrisis(text)).toBe(true);
  });

  it.each([
    'this bug is killing me',
    'How do I kill a process on Linux?',
    'My phone died again',
    'I could murder a pizza',
    'Write a story about a detective',
    '',
  ])('does not flag %j', text => {
    expect(detectCrisis(text)).toBe(false);
  });
});

describe('skills provider', () => {
  beforeEach(() => {
    clearRequestProviders();
    registerRequestProvider(createSkillsProvider());
  });
  afterAll(() => clearRequestProviders());

  const run = (text: string, session = {}) =>
    prepareRequest({messages: [{role: 'user', content: text}], session});

  it('adds nothing by default: the crisis rule waits for a crisis message', async () => {
    const result = await run('Hello');
    expect(result.messages[0].role).toBe('user');
    expect(result.meta.crisis).toBeUndefined();
    const crisis = await run('I want to end my life');
    expect(crisis.messages[0].content).toBe(getSkill(CRISIS)!.body);
  });

  it('adds study mode and the voice addendum per session', async () => {
    const result = await run('Hello', {studyMode: true, spoken: true});
    expect(result.messages[0].content).toBe(
      [getSkill(STUDY_MODE)!.body, getSkill(VOICE_MODE)!.body].join('\n\n'),
    );
  });

  it('hands the verified helpline to the model and the app on a crisis message', async () => {
    const result = await run('I want to end my life', {locale: 'en-GB'});
    expect(result.messages[1].content).toContain(
      'Samaritans, phone 116 123 (open 24/7)',
    );
    expect(result.meta.crisis).toEqual({
      countryCode: 'GB',
      helpline: helplineFor('GB'),
    });
    // Two turns later the instruction is still attached; five turns later not.
    const later = (turnsAfter: number) =>
      prepareRequest({
        messages: [
          {role: 'user', content: 'I want to end my life'},
          ...Array.from({length: turnsAfter}, (_, i) => [
            {role: 'assistant', content: 'I am here.'},
            {role: 'user', content: `ok ${i}`},
          ]).flat(),
        ],
        session: {countryCode: 'GB'},
      });
    const soon = await later(2);
    expect(soon.messages[soon.messages.length - 1].content).toContain(
      '116 123',
    );
    expect(soon.meta.crisis).toBeDefined();
    const muchLater = await later(5);
    expect(muchLater.messages[muchLater.messages.length - 1].content).toBe(
      'ok 4',
    );
    expect(muchLater.meta.crisis).toBeUndefined();

    const unknown = await run('I want to end my life');
    expect(unknown.messages[1].content).toContain('findahelpline.com');
    expect(unknown.meta.crisis).toEqual({
      countryCode: undefined,
      helpline: null,
    });
  });
});
