import {
  anyWordQuery,
  clip,
  contentStems,
  coverage,
  factSignature,
  hashText,
  jaccard,
  normalizeFact,
  slotOf,
  stem,
  stemSet,
} from '../text';

describe('memory text helpers', () => {
  it('normalises a fact for exact comparison', () => {
    expect(normalizeFact('The user is Vegetarian.')).toBe('is vegetarian');
    expect(normalizeFact("User's name is Zoë!")).toBe('name is zoe');
    expect(normalizeFact('I am a nurse')).toBe('a nurse');
    expect(normalizeFact('  User   lives in  Köln ')).toBe('lives in koln');
  });

  it('stems plurals and verb endings but leaves short words', () => {
    expect(stem('dogs')).toBe('dog');
    expect(stem('running')).toBe('runn');
    expect(stem('hobbies')).toBe('hobby');
    expect(stem('glass')).toBe('glass');
    expect(stem('cats')).toBe('cat');
    expect(stem('bus')).toBe('bus');
  });

  it('keeps content words only', () => {
    expect(contentStems('The user has two dogs and a cat')).toEqual([
      'two',
      'dog',
      'cat',
    ]);
    expect(contentStems('Ich wohne in Hamburg')).toEqual(['wohn', 'hamburg']);
    // Forms of one verb meet.
    expect(new Set(['live', 'lives', 'lived', 'living'].map(stem)).size).toBe(
      1,
    );
  });

  it('measures overlap', () => {
    const a = stemSet('User lives in Berlin');
    const b = stemSet('User lives in Berlin and works at a bank');
    expect(jaccard(a, a)).toBe(1);
    expect(jaccard(a, b)).toBeCloseTo(2 / 4);
    expect(coverage(a, b)).toBe(1);
    expect(coverage(b, a)).toBeCloseTo(0.5);
    expect(jaccard(new Set(), a)).toBe(0);
  });

  it('gives paraphrases of one fact the same signature', () => {
    expect(factSignature('User is vegetarian')).toBe(
      factSignature('The user is a vegetarian.'),
    );
    expect(factSignature('User is vegetarian')).not.toBe(
      factSignature('User is vegan'),
    );
    expect(hashText('abc')).toHaveLength(16);
    expect(hashText('abc')).not.toBe(hashText('abd'));
  });

  it('recognises single-valued slots', () => {
    expect(slotOf('User lives in Munich')).toBe('home');
    expect(slotOf('User moved to Berlin last month')).toBe('home');
    expect(slotOf('User works as a barista')).toBe('job');
    expect(slotOf('User is starting as a data analyst on Monday')).toBe('job');
    expect(slotOf("User's name is Priya")).toBe('name');
    expect(slotOf('User is vegan')).toBe('diet');
    expect(slotOf('User prefers metric units')).toBe('units');
    expect(slotOf('User loves jazz')).toBeNull();
  });

  it('clips at a word', () => {
    expect(clip('short', 20)).toBe('short');
    const cut = clip('one two three four five six seven', 18);
    expect(cut.endsWith('…')).toBe(true);
    expect(cut.length).toBeLessThanOrEqual(19);
    expect(cut).not.toContain('fiv');
  });

  it('builds an any-word full-text query', () => {
    expect(anyWordQuery('What should I cook for dinner?')).toBe(
      '"cook" OR "dinner"',
    );
    expect(anyWordQuery('the of and')).toBeNull();
    expect(anyWordQuery('say "hi" (now)')).toBe('"say" OR "hi"');
  });
});
