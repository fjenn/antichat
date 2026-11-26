import {
  classifySearchNeed,
  decideSearch,
  isConversational,
  mentionsLaterDate,
} from '../decision';
import {knowledgeCutoffFor} from '../freshTerms';
import {
  buildQueries,
  cleanModelQuery,
  dateHints,
  detectLanguage,
  isFollowUp,
  stripLeadIn,
  subQueries,
} from '../query';

const now = new Date(2026, 10, 24, 10, 0);
const decide = (userText: string, extra = {}) =>
  decideSearch({userText, knowledgeCutoff: '2026-01', ...extra});

describe('search decision', () => {
  it.each([
    ["What's the weather in Lisbon right now?", 'force', 'fresh_term'],
    ['Who won the Formula 1 race last weekend?', 'force', 'fresh_term'],
    ['Any news on the EU AI Act this week?', 'force', 'fresh_term'],
    [
      'Wie teuer ist ein Tesla Model Y aktuell in Deutschland?',
      'force',
      'fresh_term',
    ],
    ['look up the latest stable version of React Native', 'force', 'explicit'],
    ['What changed in the 2027 tax brackets?', 'force', 'later_date'],
    ['What is 17 times 23?', 'none', 'stable_task'],
    [
      "Translate 'good morning, how are you?' into Spanish.",
      'none',
      'stable_task',
    ],
    [
      'Explain in two sentences what a calendar invite is.',
      'none',
      'stable_task',
    ],
    [
      'Write a short email to my landlord asking to fix the heating.',
      'none',
      'stable_task',
    ],
    ["hey, how's it going?", 'none', 'conversational'],
    ["Thanks, that's all I needed.", 'none', 'conversational'],
    ["What's the capital of Australia?", 'auto', 'default'],
    [
      'Summarise https://example.org/blog/on-device-llms in three bullets',
      'auto',
      'has_url',
    ],
    ['tl;dr of example.net/paper.html please', 'auto', 'has_url'],
    ["What's on my calendar tomorrow?", 'auto', 'personal'],
    [
      'Check when my dentist appointment is tomorrow and email anna@example.com',
      'auto',
      'personal',
    ],
    [
      'Do I have anything with review in the title next week?',
      'auto',
      'personal',
    ],
    [
      'What is the current in a circuit with a 10 ohm resistor at 5 volts?',
      'auto',
      'default',
    ],
  ])('%s → %s (%s)', (text, decision, reason) => {
    expect(decide(text)).toMatchObject({decision, reason});
  });

  it('obeys the Search chip and leaves named tools to the model', () => {
    expect(decide('tell me about otters', {searchChip: true})).toEqual({
      decision: 'force',
      reason: 'chip',
    });
    expect(
      decide('weather in Lisbon today', {otherToolMatches: true}).decision,
    ).toBe('auto');
    expect(
      decide('what is in this photo today', {hasAttachment: true}).decision,
    ).toBe('auto');
  });

  it('recognises small talk in several languages, but not short questions', () => {
    for (const text of [
      'hi',
      'Hello!',
      'thanks a lot',
      'ok cool',
      'Danke dir',
      'merci',
      'gracias',
      'bye',
    ]) {
      expect(isConversational(text)).toBe(true);
    }
    for (const text of [
      'hi, what is the weather today?',
      'ok so who won?',
      'price of gold',
    ]) {
      expect(isConversational(text)).toBe(false);
    }
  });

  it('compares years with the model cutoff', () => {
    expect(mentionsLaterDate('the 2027 budget', '2026-01')).toBe(true);
    expect(mentionsLaterDate('events of 2026', '2026-01')).toBe(true);
    expect(mentionsLaterDate('events of 2025', '2026-01')).toBe(false);
    expect(mentionsLaterDate('call 20261234', '2026-01')).toBe(false);
    expect(knowledgeCutoffFor('gemma-4-E2B-it')).toBe('2026-03');
    expect(knowledgeCutoffFor('unknown')).toBe('2025-12');
  });

  it('reads the optional model pre-pass and survives a failing engine', async () => {
    const engine = (content: string) => ({
      completion: jest.fn(async () => ({text: content, content})),
      stopCompletion: async () => {},
    });
    const search = engine('Search');
    expect(
      await classifySearchNeed({
        engine: search as never,
        userText: 'gold price',
      }),
    ).toBe('search');
    const request = (search.completion.mock.calls as any[][])[0][0];
    expect(request.n_predict).toBeLessThanOrEqual(4);
    expect(request.response_format).toBeUndefined();
    expect(
      await classifySearchNeed({
        engine: engine('answer.') as never,
        userText: 'x',
      }),
    ).toBe('answer');
    expect(
      await classifySearchNeed({engine: engine('???') as never, userText: 'x'}),
    ).toBeNull();
    const broken = {
      completion: async () => {
        throw new Error('boom');
      },
      stopCompletion: async () => {},
    };
    expect(
      await classifySearchNeed({engine: broken as never, userText: 'x'}),
    ).toBeNull();
  });
});

describe('query rewriting', () => {
  it('strips lead-ins and politeness, keeps the question', () => {
    expect(
      stripLeadIn(
        'Can you please look up the latest stable version of React Native?',
      ),
    ).toBe('the latest stable version of React Native');
    expect(
      stripLeadIn('Tell me who won the Formula 1 race last weekend, thanks!'),
    ).toBe('who won the Formula 1 race last weekend');
    expect(
      stripLeadIn('Wie teuer ist ein Tesla Model Y aktuell in Deutschland?'),
    ).toBe('Wie teuer ist ein Tesla Model Y aktuell in Deutschland');
  });

  it('adds the date the question implies', () => {
    expect(dateHints('weather in Lisbon today', now)).toEqual([
      '24 November 2026',
    ]);
    expect(dateHints('who won the race last weekend', now)).toEqual([
      'November 2026',
    ]);
    expect(dateHints('latest stable version of React Native', now)).toEqual([
      '2026',
    ]);
    expect(dateHints('who won the 2022 world cup', now)).toEqual([]);
    expect(dateHints('how do volcanoes form', now)).toEqual([]);
    expect(
      buildQueries({userText: 'Any news on the EU AI Act this week?', now})
        .queries,
    ).toEqual(['Any news on the EU AI Act this week November 2026']);
  });

  it('resolves a follow-up from the previous question', () => {
    expect(isFollowUp('and in Germany?')).toBe(true);
    expect(isFollowUp('is it open today?')).toBe(true);
    expect(isFollowUp('Who won the Formula 1 race last weekend?')).toBe(false);
    const plan = buildQueries({
      userText: 'and in Germany?',
      previousUserTexts: [
        'How much does a Tesla Model Y cost in France right now?',
      ],
      now,
    });
    expect(plan.resolvedFollowUp).toBe(true);
    expect(plan.queries[0]).toMatch(/^in Germany Tesla Model/);
    expect(plan.queries[0]).toContain('France');
    const fresh = buildQueries({
      userText: 'What is the population of Vienna?',
      previousUserTexts: ['How much does a Tesla Model Y cost?'],
      now,
    });
    expect(fresh).toMatchObject({
      resolvedFollowUp: false,
      queries: ['What is the population of Vienna'],
    });
  });

  it('keeps the query in the user language and reports it', () => {
    expect(
      detectLanguage('Wie teuer ist ein Tesla Model Y aktuell in Deutschland?'),
    ).toBe('de');
    expect(detectLanguage('¿Cuál es el precio del oro hoy?')).toBe('es');
    expect(detectLanguage("Quel temps fait-il aujourd'hui à Lyon ?")).toBe(
      'fr',
    );
    expect(detectLanguage('What is the price of gold today?')).toBe('en');
    expect(detectLanguage('東京の天気は？')).toBe('other');
    const plan = buildQueries({
      userText: 'Wie teuer ist ein Tesla Model Y aktuell in Deutschland?',
      now,
    });
    expect(plan.language).toBe('de');
    expect(plan.queries[0]).toBe(
      'Wie teuer ist ein Tesla Model Y aktuell in Deutschland 2026',
    );
  });

  it('splits a two-part question into sub-queries when the budget allows', () => {
    expect(
      subQueries(
        'Compare the current price of the iPhone 18 Pro and the Pixel 11 Pro in the US.',
        2,
      ),
    ).toEqual([
      'Compare the current price of the iPhone 18 Pro in the US',
      'Compare the current price of the Pixel 11 Pro in the US',
    ]);
    expect(
      subQueries(
        'Who won the 2026 Nobel Prize in Physics and what was it awarded for?',
        2,
      ),
    ).toEqual([
      'Who won the 2026 Nobel Prize in Physics',
      'what was it awarded for won 2026 Nobel Prize Physics',
    ]);
    expect(subQueries('Who wrote War and Peace?', 2)).toEqual([]);
    expect(
      buildQueries({
        userText: 'Compare the populations of Lyon and Marseille',
        now,
        maxQueries: 3,
      }).queries,
    ).toHaveLength(3);
    expect(
      buildQueries({
        userText: 'Compare the populations of Lyon and Marseille',
        now,
        maxQueries: 1,
      }).queries,
    ).toHaveLength(1);
  });

  it('cleans a query the model wrote', () => {
    const context = {
      userText: 'look up the latest stable version of React Native',
      now,
    };
    expect(
      cleanModelQuery('"React Native latest stable version 2024"', context),
    ).toBe('React Native latest stable version 2026');
    expect(cleanModelQuery('', context)).toBe(
      'the latest stable version of React Native 2026',
    );
    expect(cleanModelQuery('site:reddit.com best ramen munich', {now})).toBe(
      'best ramen munich',
    );
    expect(
      cleanModelQuery('world cup 2022 winner', {
        userText: 'who won the 2022 world cup',
        now,
      }),
    ).toBe('world cup 2022 winner');
    expect(cleanModelQuery('x '.repeat(300), {now}).length).toBeLessThanOrEqual(
      200,
    );
  });
});
