import {
  cleanForContext,
  cleanModelOutput,
  findTailLoop,
  holdBackPartialMarker,
  repairUnfinishedMarkdown,
  stripSpecialTokens,
} from '../hygiene';

describe('cleanModelOutput', () => {
  it('leaves clean text alone', () => {
    const out = cleanModelOutput('Hello **world**.\n\n- one\n- two');
    expect(out.content).toBe('Hello **world**.\n\n- one\n- two');
    expect(out.reasoning).toBeNull();
    expect(out.loopDetected).toBe(false);
  });

  it.each([
    ['Hello<|im_end|>', 'Hello'],
    ['<|im_start|>assistant\nHello', 'assistant\nHello'],
    ['Answer<end_of_turn>', 'Answer'],
    ['Hi there<turn|>', 'Hi there'],
    ['Done.<|endoftext|><|endoftext|>', 'Done.'],
    ['<|startoftext|>Fine', 'Fine'],
  ])('strips leaked template tokens: %s', (raw, expected) => {
    expect(cleanModelOutput(raw).content).toBe(expected);
  });

  it('keeps template tokens inside code', () => {
    const raw = 'Use `<|im_end|>` as the stop:\n```\n<|im_start|>user\n```';
    expect(cleanModelOutput(raw).content).toBe(raw);
  });

  it('separates a <think> block from the answer', () => {
    const out = cleanModelOutput('<think>\nLet me see.\n</think>\n\nIt is 4.');
    expect(out.content).toBe('It is 4.');
    expect(out.reasoning).toBe('Let me see.');
    expect(out.reasoningComplete).toBe(true);
  });

  it('treats text before a stray </think> as thinking', () => {
    const out = cleanModelOutput('hmm, 2+2\n</think>\nFour.');
    expect(out.content).toBe('Four.');
    expect(out.reasoning).toBe('hmm, 2+2');
  });

  it('separates Gemma 4 channel thinking', () => {
    const out = cleanModelOutput(
      '<|channel>thought\nThe user greets me.<channel|>Hello!',
    );
    expect(out.content).toBe('Hello!');
    expect(out.reasoning).toBe('The user greets me.');
  });

  it('shows nothing of an open thinking block while streaming', () => {
    const out = cleanModelOutput('<think>\nStill thinking', {streaming: true});
    expect(out.content).toBe('');
    expect(out.reasoning).toContain('Still thinking');
    expect(out.reasoningComplete).toBe(false);
  });

  it('uses unfinished thinking as the answer once the run has ended', () => {
    const out = cleanModelOutput('<think>\nThe answer is 4');
    expect(out.content).toBe('The answer is 4');
    expect(out.reasoning).toBeNull();
  });

  it('holds back a half-arrived marker while streaming', () => {
    expect(cleanModelOutput('Hello<|im_e', {streaming: true}).content).toBe(
      'Hello',
    );
    expect(cleanModelOutput('Hello</thi', {streaming: true}).content).toBe(
      'Hello',
    );
    expect(holdBackPartialMarker('a < b')).toBe('a < b');
    expect(holdBackPartialMarker('if x <')).toBe('if x <');
    expect(holdBackPartialMarker('see <b')).toBe('see <b');
  });

  it('cuts a runaway repetition and reports it', () => {
    const raw = `Here is the list. ${'and then again. '.repeat(12)}`;
    const out = cleanModelOutput(raw);
    expect(out.loopDetected).toBe(true);
    expect(out.content).toBe('Here is the list. and then again.');
  });

  it('does not cut tables, code or ordinary lists', () => {
    const table = '| a | b |\n|---|---|\n| 1 | 2 |\n| 1 | 2 |\n| 1 | 2 |';
    const code = '```\nreturn result;\nreturn result;\nreturn result;\n```';
    expect(findTailLoop(table)).toBe(-1);
    expect(cleanModelOutput(code).content).toBe(code);
    expect(cleanModelOutput(table).loopDetected).toBe(false);
  });

  it('closes open markdown only when asked or streaming', () => {
    expect(cleanModelOutput('**bold').content).toBe('**bold');
    expect(cleanModelOutput('**bold', {streaming: true}).content).toBe(
      '**bold**',
    );
  });

  it('cleanForContext drops thinking and markers but keeps the text', () => {
    expect(cleanForContext('<think>x</think>Paris.<|im_end|>')).toBe('Paris.');
    expect(cleanForContext('No markup here')).toBe('No markup here');
  });

  it('handles empty input', () => {
    expect(cleanModelOutput('').content).toBe('');
    expect(stripSpecialTokens('')).toBe('');
  });
});

describe('repairUnfinishedMarkdown', () => {
  it.each([
    ['plain text', 'plain text'],
    ['done **bold** and `code`', 'done **bold** and `code`'],
    ['```js\nconst a = 1;', '```js\nconst a = 1;\n```'],
    ['```js\nconst a = 1;\n', '```js\nconst a = 1;\n```'],
    ['~~~\nx', '~~~\nx\n~~~'],
    ['some **bold te', 'some **bold te**'],
    ['some **', 'some '],
    ['some *ital', 'some *ital*'],
    ['run `npm inst', 'run `npm inst`'],
    ['see [the docs](https://exa', 'see the docs'],
    ['pic ![alt](https://exa', 'pic '],
    ['Euler: $$e^{i\\pi}', 'Euler: $$e^{i\\pi}\n$$'],
    ['so \\(x^2', 'so \\(x^2\\)'],
    ['so \\[x^2', 'so \\[x^2\\]'],
    ['text ~~gone', 'text ~~gone~~'],
    ['List:\n- one\n- ', 'List:\n- one'],
    ['Title\n## ', 'Title'],
    ['* item one\n* item two', '* item one\n* item two'],
    ['2 * 3 = 6', '2 * 3 = 6'],
  ])('%j', (input, expected) => {
    expect(repairUnfinishedMarkdown(input).text).toBe(expected);
  });

  it('reports what was open', () => {
    expect(repairUnfinishedMarkdown('```py\nx').open.codeFence).toBe(true);
    expect(repairUnfinishedMarkdown('a **b').open.bold).toBe(true);
    expect(repairUnfinishedMarkdown('a [b](c').open.link).toBe(true);
    expect(repairUnfinishedMarkdown('fine').open).toEqual({
      codeFence: false,
      inlineCode: false,
      bold: false,
      italic: false,
      strikethrough: false,
      math: false,
      link: false,
    });
  });

  it('does not touch markdown inside an open code fence', () => {
    expect(repairUnfinishedMarkdown('```md\n**not bold').text).toBe(
      '```md\n**not bold\n```',
    );
  });

  it('is stable on finished text with closed fences', () => {
    const done = 'A\n\n```js\nlet a = "**";\n```\n\nB **b**';
    expect(repairUnfinishedMarkdown(done).text).toBe(done);
  });
});
