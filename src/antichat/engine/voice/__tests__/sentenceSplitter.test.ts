import {
  SentenceSplitter,
  splitSentences,
  type SpeechUnit,
  type SplitterOptions,
} from '../tts/sentenceSplitter';

const raws = (text: string, language?: string) =>
  splitSentences(text, {language}).map(u => u.raw.trim());

/** Feeds the text one character at a time, as a model would. */
function stream(text: string, options: SplitterOptions = {}) {
  const splitter = new SentenceSplitter(options);
  const units: SpeechUnit[] = [];
  for (const ch of text) {
    units.push(...splitter.push(ch));
  }
  units.push(...splitter.flush());
  return units;
}

describe('SentenceSplitter', () => {
  it('splits plain sentences', () => {
    expect(
      raws('Paris is the capital. It has two million people! Really? Yes.'),
    ).toEqual([
      'Paris is the capital.',
      'It has two million people!',
      'Really?',
      'Yes.',
    ]);
  });

  it('keeps abbreviations, initials and titles together', () => {
    expect(raws('Dr. Smith met Mr. Jones, e.g. at noon. They talked.')).toEqual(
      ['Dr. Smith met Mr. Jones, e.g. at noon.', 'They talked.'],
    );
    expect(raws('J. K. Rowling wrote it. So did J. R. R. Tolkien.')).toEqual([
      'J. K. Rowling wrote it.',
      'So did J. R. R. Tolkien.',
    ]);
    expect(raws('See No. 5 and ca. 20 others. No. That is all.')).toEqual([
      'See No. 5 and ca. 20 others.',
      'No.',
      'That is all.',
    ]);
    expect(raws('It lives in the U.S. and the U.K. today. Good.')).toHaveLength(
      2,
    );
  });

  it('does not split numbers, versions, times or URLs', () => {
    expect(
      raws(
        'Pi is 3.14159 and e is 2.718. Version 1.2.3 is out at example.com/a.b now.',
      ),
    ).toEqual([
      'Pi is 3.14159 and e is 2.718.',
      'Version 1.2.3 is out at example.com/a.b now.',
    ]);
    expect(raws('It costs $1,299.99 today. Buy it.')).toHaveLength(2);
  });

  it('does not split inside inline code', () => {
    expect(raws('Call `a.b. C` first. Then stop.')).toEqual([
      'Call `a.b. C` first.',
      'Then stop.',
    ]);
  });

  it('handles quotes, brackets and emphasis after the full stop', () => {
    expect(
      raws('He said "stop." Then he left. (It was late.) **Done.** Next.'),
    ).toEqual([
      'He said "stop."',
      'Then he left.',
      '(It was late.)',
      '**Done.**',
      'Next.',
    ]);
  });

  it('treats an ellipsis and a lowercase continuation as one sentence', () => {
    expect(raws('Well... maybe not. Wait… Yes.')).toEqual([
      'Well... maybe not.',
      'Wait…',
      'Yes.',
    ]);
  });

  it('makes list items, headings and table rows their own units', () => {
    const units = splitSentences(
      '# Plan\n\n1. First step\n2. Second step. With detail.\n- a bullet\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\nDone.',
    );
    expect(units.map(u => [u.kind, u.raw.trim()])).toEqual([
      ['heading', '# Plan'],
      ['list', '1. First step'],
      ['list', '2. Second step.'],
      ['sentence', 'With detail.'],
      ['list', '- a bullet'],
      ['table', '| A | B |'],
      ['table', '|---|---|'],
      ['table', '| 1 | 2 |'],
      ['sentence', 'Done.'],
    ]);
  });

  it('takes a code block as one unit', () => {
    const units = splitSentences(
      'Here you go:\n\n```python\nprint("a. B")\nx = 1. \n```\n\nThat prints it.',
    );
    expect(units.map(u => u.kind)).toEqual(['sentence', 'code', 'sentence']);
    expect(units[1]!.raw).toContain('print("a. B")');
    expect(units[2]!.raw).toBe('That prints it.');
  });

  it('drops reasoning blocks', () => {
    expect(
      raws('<think>Hmm. Let me think. Ok.</think>The answer is four.'),
    ).toEqual(['The answer is four.']);
  });

  it('German: ordinals and abbreviations', () => {
    expect(
      raws('Wir treffen uns am 3. Mai, z.B. um acht. Bis dann.', 'de'),
    ).toEqual(['Wir treffen uns am 3. Mai, z.B. um acht.', 'Bis dann.']);
    // Without the German rule, "3. Mai" would split.
    expect(raws('We meet on the 3. Maybe.', 'en')).toHaveLength(2);
  });

  it('CJK full stops need no space', () => {
    expect(raws('你好。今天天气很好！是吗？')).toEqual([
      '你好。',
      '今天天气很好！',
      '是吗？',
    ]);
  });

  it('offsets point back into the source text', () => {
    const text = 'One.  Two is longer.\n\nThree.';
    for (const unit of splitSentences(text)) {
      expect(text.slice(unit.start, unit.end)).toBe(unit.raw);
    }
  });

  describe('streaming', () => {
    const text =
      'Sure. The capital of France is Paris, e.g. the city of light. It has 2.1 million people.\n\n- One\n- Two';

    it('gives the same units character by character as in one piece', () => {
      expect(stream(text).map(u => u.raw)).toEqual(
        splitSentences(text).map(u => u.raw),
      );
    });

    it('releases a sentence as soon as the next one begins, not before', () => {
      const splitter = new SentenceSplitter();
      expect(splitter.push('Hello there.')).toEqual([]);
      expect(splitter.push(' ')).toEqual([]);
      expect(splitter.push('N').map(u => u.raw)).toEqual(['Hello there.']);
      expect(splitter.push('ext one')).toEqual([]);
      expect(splitter.flush().map(u => u.raw)).toEqual(['Next one']);
    });

    it('holds a code fence until it closes, even when the fence arrives in pieces', () => {
      const splitter = new SentenceSplitter();
      expect(splitter.push('``')).toEqual([]);
      expect(splitter.push('`js\nlet a = 1. B\n')).toEqual([]);
      expect(splitter.push('``')).toEqual([]);
      const units = splitter.push('`\nDone');
      expect(units.map(u => u.kind)).toEqual(['code']);
      expect(splitter.flush().map(u => u.raw)).toEqual(['Done']);
    });

    it('first clause: a long opening sentence starts at its first comma', () => {
      const long =
        'The capital of France is Paris, which has been the seat of government for a very long time and remains so today. Next.';
      const units = stream(long, {firstClause: true});
      expect(units[0]!.raw).toBe('The capital of France is Paris,');
      expect(units.map(u => u.raw).join(' ')).toBe(long);
    });

    it('cuts a sentence that never ends', () => {
      const endless = 'word '.repeat(200);
      const units = stream(endless, {maxChars: 120});
      expect(units.length).toBeGreaterThan(5);
      expect(Math.max(...units.map(u => u.raw.length))).toBeLessThanOrEqual(
        120,
      );
    });
  });
});
