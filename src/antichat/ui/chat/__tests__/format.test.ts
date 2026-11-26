import '../../../testing/setup';

import {
  errorMessage,
  flowMarkdown,
  formatThinkingTime,
  isLoadableImage,
  withQuote,
} from '../format';

describe('chat formatting', () => {
  it('words thinking time in seconds, then minutes', () => {
    expect(formatThinkingTime(400)).toBe('1s');
    expect(formatThinkingTime(5200)).toBe('5s');
    expect(formatThinkingTime(80_000)).toBe('1m 20s');
  });

  it('words every error itself and never shows the detail', () => {
    expect(
      errorMessage({code: 'model_not_loaded', retryable: true, detail: 'raw'}),
    ).toBe('The model isn’t loaded yet.');
    expect(errorMessage(undefined)).toBe('The answer stopped early.');
  });

  it('quotes every line of the selected passage', () => {
    expect(withQuote('Why?', 'a\nb')).toBe('> a\n> b\n\nWhy?');
    expect(withQuote('Why?', null)).toBe('Why?');
  });

  it('turns table rows into lines for the select-text sheet', () => {
    const table = '| Part | Cost |\n| --- | :---: |\n| Attention | High |';
    expect(flowMarkdown(`Intro\n\n${table}\n\nEnd`)).toBe(
      'Intro\n\nPart · Cost  \nAttention · High  \n\nEnd',
    );
    // Code keeps its pipes and dashes.
    const code = '```sh\n| a | b |\n---\n```';
    expect(flowMarkdown(code)).toBe(code);
  });

  it('only loads images from real locations', () => {
    expect(isLoadableImage('file:///tmp/a.jpg')).toBe(true);
    expect(isLoadableImage('fake://photo/1')).toBe(false);
  });
});
