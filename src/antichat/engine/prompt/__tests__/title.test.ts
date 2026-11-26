import {createFakeEngine} from '../../context/__tests__/support/fakeEngine';
import {
  TITLE_INLINE_INSTRUCTION,
  TITLE_MAX_CHARS,
  TITLE_SYSTEM_PROMPT,
  buildTitleMessages,
  fallbackTitle,
  generateTitle,
  guessLatinLanguage,
  isTooShortToName,
  sanitizeTitle,
  titleMatchesLanguage,
  titleMatchesScript,
} from '../title';

describe('sanitizeTitle', () => {
  it.each([
    ['Lisbon Budget Trip Plan', 'Lisbon Budget Trip Plan'],
    ['"Lisbon Budget Trip Plan"', 'Lisbon Budget Trip Plan'],
    ['Title: Lisbon Budget Trip', 'Lisbon Budget Trip'],
    ['Subject: Thank you for covering', 'Thank you for covering'],
    ['**Virus vs Bacteria**', 'Virus vs Bacteria'],
    ['# Virus vs Bacteria', 'Virus vs Bacteria'],
    ['Virus vs. Bacteria.', 'Virus vs. Bacteria'],
    ['Removing Red Wine Stains!', 'Removing Red Wine Stains'],
    ['Weiches Ei kochen 🥚', 'Weiches Ei kochen'],
    ['«Aprender inglés rápido»', 'Aprender inglés rápido'],
    [
      '\n\nPython palindrome function\nHere is why…',
      'Python palindrome function',
    ],
    ['Help me assist you with', 'Help me assist you'],
    ['Método de 30 días para', 'Método de 30 días'],
    ['Научиться печатать быстро на', 'Научиться печатать быстро'],
    ['提高睡眠质量方法', '提高睡眠质量方法'],
    ['「東京ラーメン推薦」', '東京ラーメン推薦'],
    ['One two three four five six seven', 'One two three four five'],
  ])('%j → %j', (raw, expected) => {
    expect(sanitizeTitle(raw)).toBe(expected);
  });

  it.each([
    [''],
    ['   \n '],
    ['Greetings'],
    ['<think>'],
    ['{"title": "x y"}'],
    ['Sure! Here is a title for the conversation you asked me to name today'],
    ['東京のラーメン屋として人気が高いものをいくつか紹介しますね'],
    ['The and'],
  ])('rejects %j', raw => {
    expect(sanitizeTitle(raw)).toBeNull();
  });

  it('never returns more than 36 characters or trailing punctuation', () => {
    const samples = [
      'Understanding Extraordinarily Complicated Mortgage Arrangements',
      'Internationalization considerations, explained: thoroughly!',
      'A title that goes on and on and on?',
      'Différence passé composé imparfait',
    ];
    for (const sample of samples) {
      const title = sanitizeTitle(sample);
      if (title !== null) {
        expect(title.length).toBeLessThanOrEqual(TITLE_MAX_CHARS);
        expect(title).not.toMatch(/[.,;:!?…\s-]$/);
      }
    }
  });
});

describe('fallbackTitle', () => {
  it('breaks at a word and drops dangling words and punctuation', () => {
    expect(fallbackTitle('How do I get red wine out of a white carpet?')).toBe(
      'How do I get red wine out of a white',
    );
    expect(fallbackTitle('hi')).toBe('Hi');
    expect(fallbackTitle('  what   is\nlove?  ')).toBe('What is love');
    expect(fallbackTitle('')).toBe('New chat');
    expect(fallbackTitle('```js\nlet a = 1\n```')).toBe('New chat');
  });

  it('stays within the limit for any script', () => {
    const inputs = [
      'x'.repeat(200),
      '東京でおすすめのラーメン屋を教えてください。それから寿司屋もお願いします。',
      'Как научиться быстро печатать на клавиатуре без ошибок и усталости?',
    ];
    for (const input of inputs) {
      const title = fallbackTitle(input);
      expect(title.length).toBeLessThanOrEqual(TITLE_MAX_CHARS);
      expect(title).not.toMatch(/[.,;:!?…。？\s]$/);
    }
  });
});

describe('language guards', () => {
  it('rejects a Latin title for a non-Latin message', () => {
    expect(
      titleMatchesScript('Tokyo Ramen Tips', '東京でおすすめのラーメン屋'),
    ).toBe(false);
    expect(
      titleMatchesScript('東京ラーメン', '東京でおすすめのラーメン屋'),
    ).toBe(true);
    expect(
      titleMatchesScript('Typing Speed', 'Как научиться быстро печатать'),
    ).toBe(false);
    expect(titleMatchesScript('Anything Goes', 'How do I cook rice?')).toBe(
      true,
    );
  });

  it('guesses clear Latin-script languages only', () => {
    expect(
      guessLatinLanguage('Wie koche ich ein weiches Ei, ohne dass es platzt?'),
    ).toBe('de');
    expect(
      guessLatinLanguage('¿Cuál es la mejor manera de aprender inglés rápido?'),
    ).toBe('es');
    expect(
      guessLatinLanguage('How do I get red wine out of a white carpet?'),
    ).toBe('en');
    expect(guessLatinLanguage('Carbonara')).toBeNull();
  });

  it('rejects an English title for a clearly non-English chat', () => {
    const es = '¿Cuál es la mejor manera de aprender inglés rápido?';
    expect(titleMatchesLanguage('How to learn English fast', es)).toBe(false);
    expect(titleMatchesLanguage('Aprender inglés rápido', es)).toBe(true);
    const it = 'Dammi una ricetta semplice per la carbonara.';
    expect(titleMatchesLanguage('Carbonara recipe request', it)).toBe(false);
    expect(titleMatchesLanguage('Ricetta semplice carbonara', it)).toBe(true);
    const nl = 'Hoe schrijf ik een goede sollicitatiebrief?';
    expect(titleMatchesLanguage('Job Seeker Guide', nl)).toBe(false);
    expect(titleMatchesLanguage('Sollicitatiebrief schrijven', nl)).toBe(true);
  });

  it('lets any title through for English or undetermined messages', () => {
    expect(
      titleMatchesLanguage(
        'Mindset Shift',
        'I feel really unmotivated at work lately and I do not know why.',
      ),
    ).toBe(true);
    expect(titleMatchesLanguage('Pasta Night', 'Carbonara?')).toBe(true);
  });
});

describe('generateTitle', () => {
  const user =
    'Plan a 3 day trip to Lisbon in March for two people on a budget.';

  it('asks the model and returns the cleaned title', async () => {
    const engine = createFakeEngine();
    engine.titleFor = () => '"Lisbon Budget Trip Plan."';
    const result = await generateTitle({engine, userMessage: user});
    expect(result).toMatchObject({
      title: 'Lisbon Budget Trip Plan',
      generated: true,
    });
    const call = engine.calls[0];
    expect(call.messages[0].content).toBe(TITLE_SYSTEM_PROMPT);
    expect(call.params.enable_thinking).toBe(false);
    expect(call.params.n_predict).toBeLessThanOrEqual(32);
  });

  it('falls back to the user words when the model output is unusable', async () => {
    const engine = createFakeEngine();
    engine.titleFor = () => 'Sure';
    const result = await generateTitle({engine, userMessage: user});
    expect(result.generated).toBe(false);
    expect(result.title).toBe('Plan a 3 day trip to Lisbon in March');
  });

  it('keeps the title in the user language: wrong script or language → fallback', async () => {
    const engine = createFakeEngine();
    engine.titleFor = () => 'Tokyo Ramen Recommendations';
    const ja = await generateTitle({
      engine,
      userMessage: '東京でおすすめのラーメン屋を教えてください。',
    });
    expect(ja.generated).toBe(false);
    expect(ja.title).toBe('東京でおすすめのラーメン屋を教えてくださ');

    engine.titleFor = () => 'How to learn English fast';
    const es = await generateTitle({
      engine,
      userMessage: '¿Cuál es la mejor manera de aprender inglés rápido?',
    });
    expect(es.generated).toBe(false);
    expect(es.title).toBe('¿Cuál es la mejor manera de aprender');

    engine.titleFor = () => 'Aprender inglés rápido';
    const ok = await generateTitle({
      engine,
      userMessage: '¿Cuál es la mejor manera de aprender inglés rápido?',
    });
    expect(ok).toMatchObject({
      title: 'Aprender inglés rápido',
      generated: true,
    });
  });

  it('does not ask the model to name a greeting', async () => {
    const engine = createFakeEngine();
    expect(isTooShortToName('hi')).toBe(true);
    expect(isTooShortToName('weather in Graz?')).toBe(false);
    const result = await generateTitle({engine, userMessage: 'hi'});
    expect(result).toEqual({title: 'Hi', generated: false});
    expect(engine.calls).toHaveLength(0);
  });

  it('survives an engine failure', async () => {
    const engine = createFakeEngine();
    engine.completion = jest.fn().mockRejectedValue(new Error('boom'));
    const result = await generateTitle({engine, userMessage: user});
    expect(result.generated).toBe(false);
    expect(result.title.length).toBeLessThanOrEqual(TITLE_MAX_CHARS);
  });

  it('can ask as one more turn of the chat to reuse its cache', () => {
    const chatMessages = [
      {role: 'system', content: 'S'},
      {role: 'user', content: user},
    ];
    const messages = buildTitleMessages({
      engine: createFakeEngine(),
      userMessage: user,
      assistantReply: 'Here is a plan.',
      chatMessages,
    });
    expect(messages.slice(0, 2)).toEqual(chatMessages);
    expect(messages[2]).toEqual({
      role: 'assistant',
      content: 'Here is a plan.',
    });
    expect(messages[3].content).toBe(TITLE_INLINE_INSTRUCTION);
  });
});
