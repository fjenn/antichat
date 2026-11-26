import {normalizeForSpeech, stripMarkdown} from '../tts/normalize';
import {
  BUILTIN_PRONUNCIATIONS,
  PronunciationLexicon,
} from '../tts/pronunciation';

const say = (raw: string, language = 'en') =>
  normalizeForSpeech(raw, {language});

describe('normalizeForSpeech', () => {
  it('removes Markdown but keeps the words', () => {
    expect(say('**Paris** is the *capital* of __France__.')).toBe(
      'Paris is the capital of France.',
    );
    expect(say('## The plan')).toBe('The plan');
    expect(say('> quoted text')).toBe('quoted text');
    expect(say('- [x] buy milk')).toBe('buy milk');
    expect(say('3. Third step')).toBe('3, Third step');
    expect(say('Use `npm install` now')).toBe('Use npm install now');
    expect(say('~~old~~ new')).toBe('old new');
    expect(say('snake_case_name stays')).toBe('snake_case_name stays');
    expect(say('2 * 3 * 4')).toBe('2 * 3 * 4');
  });

  it('reads links by their text and bare URLs by their host', () => {
    expect(say('See [the docs](https://example.com/a/b?c=1) for more.')).toBe(
      'See the docs for more.',
    );
    expect(say('Go to https://www.example.com/path/page.html now')).toBe(
      'Go to example.com now',
    );
    expect(say('![a cat](cat.png) sits')).toBe('a cat sits');
  });

  it('drops citations, footnotes, HTML and emoji', () => {
    expect(say('Paris[1] is big[^2] 【3†source】.')).toBe('Paris is big.');
    expect(say('A<br>B <b>bold</b>')).toBe('A B bold');
    expect(say('Great job! 🎉👍🏽')).toBe('Great job!');
    expect(say('🙂')).toBe('');
    expect(say('---')).toBe('');
  });

  it('reads table rows as lists and skips the rule row', () => {
    expect(normalizeForSpeech('| Name | Age |', {kind: 'table'})).toBe(
      'Name, Age',
    );
    expect(normalizeForSpeech('|---|:--:|', {kind: 'table'})).toBe('');
  });

  it('replaces a code block by a short sentence', () => {
    expect(
      normalizeForSpeech('```js\nx\n```', {kind: 'code', language: 'en'}),
    ).toBe('Here is a code example.');
    expect(
      normalizeForSpeech('```js\nx\n```', {kind: 'code', language: 'de-DE'}),
    ).toBe('Hier ist ein Codebeispiel.');
    expect(
      normalizeForSpeech('```js\nx\n```', {kind: 'code', language: 'ja'}),
    ).toBe('');
    expect(
      normalizeForSpeech('```\nx\n```', {kind: 'code', codePlaceholder: ''}),
    ).toBe('');
  });

  it('spells out symbols, units and currency (English)', () => {
    expect(say('It costs $5.50 or 5 €.')).toBe(
      'It costs 5.50 dollars or 5 euros.',
    );
    expect(say('Up 20% at 30°C')).toBe('Up 20 percent at 30 degrees Celsius');
    expect(say('Run 5 km in 3-4 hours at 10 km/h')).toBe(
      'Run 5 kilometers in 3 to 4 hours at 10 kilometers per hour',
    );
    expect(say('16GB RAM & 2 + 2 = 4')).toBe(
      '16 gigabytes RAM and 2 plus 2 equals 4',
    );
    expect(say('3x faster, ~5 items')).toBe('3 times faster, about 5 items');
    expect(say('on 2024-05-01')).toBe('on 2024-05-01');
    expect(say('A -> B')).toBe('A, B');
  });

  it('expands abbreviations per language', () => {
    expect(say('Fruit, e.g. apples, i.e. pomes, etc.')).toBe(
      'Fruit, for example, apples, that is, pomes, et cetera.',
    );
    expect(say('Obst, z.B. Äpfel, usw.', 'de')).toBe(
      'Obst, zum Beispiel Äpfel, und so weiter.',
    );
    expect(say('Es kostet 5 € bzw. 20%', 'de')).toBe(
      'Es kostet 5 Euro beziehungsweise 20 Prozent',
    );
    expect(say('Cuesta 10 km, p. ej. hoy', 'es')).toBe(
      'Cuesta 10 kilómetros, por ejemplo hoy',
    );
    expect(say('Il fait 20°C, p.ex. ici', 'fr')).toBe(
      'Il fait 20 degrés Celsius, par exemple ici',
    );
  });

  it('leaves other languages alone apart from markup', () => {
    expect(say('**こんにちは** 5km', 'ja')).toBe('こんにちは 5km');
  });

  it('stripMarkdown keeps reasoning out', () => {
    expect(stripMarkdown('<think>secret</think>Hello').trim()).toBe('Hello');
  });
});

describe('PronunciationLexicon', () => {
  it('applies built-in fixes on whole words only', () => {
    const lexicon = new PronunciationLexicon();
    expect(lexicon.apply('The API returns JSON on iOS.', 'en')).toBe(
      'The A P I returns jason on eye O S.',
    );
    expect(lexicon.apply('APIs and RAPID', 'en')).toBe('A P Is and RAPID');
    expect(lexicon.apply('an api call', 'en')).toBe('an api call');
  });

  it('respects the language of an entry', () => {
    const lexicon = new PronunciationLexicon();
    expect(lexicon.apply('JSON auf iOS', 'de')).toBe('JSON auf iOS');
    expect(lexicon.apply('Die API', 'de')).toBe('Die A P I');
  });

  it('user entries override built-ins and can be removed', () => {
    const lexicon = new PronunciationLexicon([{word: 'SQL', say: 'S Q L'}]);
    expect(lexicon.apply('SQL and sql', 'en')).toBe('S Q L and S Q L');
    lexicon.add({word: 'Nguyen', say: 'win'});
    expect(lexicon.apply('Hi Nguyen!', 'en')).toBe('Hi win!');
    expect(lexicon.toJSON()).toHaveLength(2);
    lexicon.remove('sql');
    expect(lexicon.apply('SQL', 'en')).toBe('sequel');
    lexicon.add({word: ' ', say: 'x'});
    expect(lexicon.userEntries).toHaveLength(1);
  });

  it('built-ins are well-formed', () => {
    for (const entry of BUILTIN_PRONUNCIATIONS) {
      expect(entry.word.trim()).toBe(entry.word);
      expect(entry.say.length).toBeGreaterThan(0);
    }
  });
});
