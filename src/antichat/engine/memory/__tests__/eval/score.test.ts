import type {EvalCase} from './extractionSet';
import {EXTRACTION_SET} from './extractionSet';
import {HOLDOUT_SET} from './holdoutSet';
import {matches, scoreCase, totals} from './score';

const written = (text: string) => ({text, unchangedSeed: false});
const seed = (text: string) => ({text, unchangedSeed: true});

const moved: EvalCase = {
  id: 'moved',
  category: 'seeded',
  seed: ['User lives in Chicago', 'User has a cat named Olive'],
  turns: [{user: 'We moved to Denver.', assistant: 'Nice.'}],
  expect: [{label: 'Denver', all: ['denver']}],
  kept: [{label: 'Olive', all: ['olive']}],
  allow: [{label: 'altitude', all: ['altitude']}],
  forbid: [
    {label: 'still Chicago', all: ['chicago'], none: ['denver|moved from']},
  ],
};

describe('extraction scoring', () => {
  it('matches case- and accent-insensitively, with exclusions', () => {
    expect(
      matches({label: '', all: ['disenadora']}, 'Usuaria es Diseñadora'),
    ).toBe(true);
    expect(matches({label: '', all: ['a', 'b']}, 'only a')).toBe(false);
    expect(
      matches(
        {label: '', all: ['chicago'], none: ['denver']},
        'Moved from Chicago to Denver',
      ),
    ).toBe(false);
  });

  it('scores a perfect update', () => {
    const score = scoreCase(moved, [
      seed('User has a cat named Olive'),
      written('User lives in Denver'),
    ]);
    expect(score).toMatchObject({
      expected: 1,
      found: 1,
      written: 1,
      correct: 1,
      forbidden: 0,
      stale: 0,
      lost: 0,
      wrong: [],
      missed: [],
    });
  });

  it('counts a stale seed, a lost seed, a repeat and a spurious memory', () => {
    const score = scoreCase(moved, [
      seed('User lives in Chicago'),
      written('User moved to Denver'),
      written('User is now based in Denver, Colorado'),
      written('User asked about hiking boots'),
      written('User worries about altitude'),
    ]);
    expect(score).toMatchObject({
      found: 1,
      written: 4,
      correct: 1,
      redundant: 1,
      spurious: 1,
      allowed: 1,
      stale: 1,
      lost: 1,
    });
    expect(score.missed).toEqual([]);
  });

  it('counts a written memory that matches a forbid label', () => {
    const score = scoreCase(moved, [
      seed('User has a cat named Olive'),
      written('User lives in Chicago with a cat'),
    ]);
    expect(score).toMatchObject({forbidden: 1, found: 0, missed: ['Denver']});
  });

  it('lets the more specific memory claim a label first', () => {
    const named: EvalCase = {
      id: 'named',
      category: 'facts',
      turns: [{user: "I'm Priya, a nurse.", assistant: 'Hi.'}],
      expect: [
        {label: 'name', all: ['priya']},
        {label: 'nurse', all: ['nurse']},
      ],
    };
    const score = scoreCase(named, [
      written('Priya works as a nurse'),
      written("User's name is Priya"),
    ]);
    expect(score).toMatchObject({correct: 2, redundant: 0, found: 2});
  });

  it('treats a second copy of a kept seed as clutter', () => {
    const score = scoreCase(moved, [
      seed('User has a cat named Olive'),
      written('User owns a cat called Olive'),
      written('User lives in Denver'),
    ]);
    expect(score).toMatchObject({redundant: 1, correct: 1});
  });

  it('sums up precision, recall and clean cases', () => {
    const total = totals([
      scoreCase(moved, [
        seed('User has a cat named Olive'),
        written('User lives in Denver'),
      ]),
      scoreCase(moved, [
        seed('User has a cat named Olive'),
        seed('User lives in Chicago'),
        written('User likes tea'),
      ]),
    ]);
    expect(total).toMatchObject({
      cases: 2,
      expected: 2,
      found: 1,
      correct: 1,
      spurious: 1,
      stale: 1,
      cleanCases: 1,
    });
    expect(total.recall).toBeCloseTo(0.5);
    expect(total.precision).toBeCloseTo(1 / 3);
    expect(totals([]).precision).toBe(1);
  });

  it('has well-formed case sets', () => {
    const all = [...EXTRACTION_SET, ...HOLDOUT_SET];
    expect(EXTRACTION_SET).toHaveLength(44);
    expect(HOLDOUT_SET).toHaveLength(16);
    expect(new Set(all.map(c => c.id)).size).toBe(all.length);
    for (const testCase of all) {
      expect(testCase.turns.length).toBeGreaterThan(0);
      const matchers = [
        ...testCase.expect,
        ...(testCase.allow ?? []),
        ...(testCase.forbid ?? []),
        ...(testCase.kept ?? []),
      ];
      for (const matcher of matchers) {
        for (const pattern of [...matcher.all, ...(matcher.none ?? [])]) {
          expect(() => new RegExp(pattern, 'i')).not.toThrow();
        }
      }
      // Every kept label must hold for some seed, and no seed may start
      // out matching an expectation.
      for (const kept of testCase.kept ?? []) {
        expect((testCase.seed ?? []).some(s => matches(kept, s))).toBe(true);
      }
      for (const expected of testCase.expect) {
        expect((testCase.seed ?? []).some(s => matches(expected, s))).toBe(
          false,
        );
      }
    }
  });
});
