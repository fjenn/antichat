import {
  EXTRACTION_EXAMPLES,
  EXTRACTION_RULES,
  EXTRACTION_SYSTEM_PROMPT,
  buildExtractionMessages,
  extractionStyleFor,
  detectSensitive,
  extractFacts,
  hasForgetCue,
  hasMemoryCue,
  hasRememberCue,
  parseExtraction,
  parseJsonLoose,
  prepareUserTurns,
  screenFacts,
  trimFact,
  type ExtractedFact,
} from '../extraction';
import {createScriptedEngine} from './support/scriptedEngine';

const fact = (
  text: string,
  extra: Partial<ExtractedFact> = {},
): ExtractedFact => ({
  text,
  kind: 'profile',
  sensitive: null,
  explicit: false,
  ...extra,
});
const texts = (facts: ExtractedFact[]) => facts.map(f => f.text);

describe('remember cues', () => {
  it.each([
    'Remember that I am vegetarian',
    "Please don't forget my sister is called Mia",
    'From now on, answer in British English',
    'Merk dir, dass ich Vegetarier bin',
    "Souviens-toi que je m'appelle Camille",
    'Recuerda que soy alérgico a los frutos secos',
    'Lembre-se de que moro em Lisboa',
    'Onthoud dat ik in Utrecht woon',
    'for future reference, I use metric',
  ])('hears "%s"', text => {
    expect(hasRememberCue(text)).toBe(true);
  });

  it.each([
    'Do you remember the capital of Peru?',
    'I can never remember names',
    'What is a good way to memorise vocabulary?',
    'I am vegetarian',
  ])('does not hear one in "%s"', text => {
    expect(hasRememberCue(text)).toBe(false);
  });

  it('tells standing instructions and forget requests apart', () => {
    expect(hasMemoryCue('Always answer in bullet points')).toBe(true);
    expect(hasRememberCue('Always answer in bullet points')).toBe(false);
    expect(hasForgetCue('Forget that I live in Lyon')).toBe(true);
    expect(hasForgetCue("Don't forget the milk")).toBe(false);
  });
});

describe('detectSensitive', () => {
  it.each([
    ['User was diagnosed with type 2 diabetes', 'health'],
    ['User takes sertraline', 'health'],
    ['User is gay', 'sexuality'],
    ['User is Muslim', 'religion'],
    ['User always votes Green', 'politics'],
    ['User earns 52,000 a year', 'finances'],
    ['User has 18k in credit card debt', 'finances'],
    ["User's passport number is X1234567", 'identity'],
  ])('flags "%s" as %s', (text, category) => {
    expect(detectSensitive(text)).toBe(category);
  });

  it.each([
    ['Nutzer hat Diabetes und nimmt Medikamente', 'health'],
    ['Nutzerin ist schwanger', 'health'],
    ["L'utilisateur est musulman", 'religion'],
    ['El usuario es homosexual', 'sexuality'],
    ['Nutzer verdient 4200 Euro, das Gehalt reicht nicht', 'finances'],
    ['La usuaria tiene deudas', 'finances'],
    ['Gebruiker stemt op een linkse partij', 'politics'],
    ['Le mot de passe de l’utilisateur est soleil', 'identity'],
  ])('flags "%s" (other languages) as %s', (text, category) => {
    expect(detectSensitive(text)).toBe(category);
  });

  it.each([
    'Nutzerin wohnt in Hamburg und ist Lehrerin für Mathematik',
    'Usuaria es diseñadora gráfica y vive en Valencia',
    "L'utilisateur s'appelle Camille",
    'Gebruiker studeert rechten in Utrecht en speelt hockey',
    'Die Tochter des Nutzers heißt Lena und hat am 3. Mai Geburtstag',
  ])('leaves "%s" alone', text => {
    expect(detectSensitive(text)).toBeNull();
  });

  it.each([
    'User is vegetarian',
    'User is allergic to shellfish',
    'User loves cooking Persian food',
    'User lives in Austin and has two kids',
    'User is a software developer',
  ])('leaves "%s" alone', text => {
    expect(detectSensitive(text)).toBeNull();
  });
});

describe('prepareUserTurns', () => {
  it('drops code, quotes and pasted walls of text', () => {
    const turns = prepareUserTurns([
      'Why does this fail?\n```python\nprint(x[9])\n```\nI am new to Python.',
      '> quoted line from an email\nWhat should I answer?',
      `Summarise this:\n${'lorem ipsum '.repeat(40)}`,
    ]);
    expect(turns).toEqual([
      'Why does this fail? I am new to Python.',
      'What should I answer?',
      'Summarise this:',
    ]);
  });

  it('drops quoted passages: they are text to work on, not the user', () => {
    expect(
      prepareUserTurns([
        "Translate to French: 'I am a doctor and I live in Paris with my three cats.'",
        'Fix this: "I has two brothers and lives in Rome since 2019." Thanks, I am Dutch btw.',
        'My dog is called "Mr Bean".',
      ]),
    ).toEqual([
      'Translate to French:',
      'Fix this: Thanks, I am Dutch btw.',
      'My dog is called "Mr Bean".',
    ]);
  });

  it('keeps the newest turns when there are too many', () => {
    const turns = prepareUserTurns(
      Array.from({length: 30}, (_, i) => `message number ${i}`),
    );
    expect(turns).toHaveLength(10);
    expect(turns[9]).toBe('message number 29');
    const long = prepareUserTurns(
      Array.from(
        {length: 10},
        (_, i) => `${i} ${'word '.repeat(50)}\n${'more '.repeat(50)}`,
      ),
    );
    expect(long.join('').length).toBeLessThanOrEqual(3300);
    expect(long[long.length - 1].startsWith('9 ')).toBe(true);
  });
});

describe('parseExtraction', () => {
  it('reads our shape', () => {
    expect(
      parseExtraction(
        '{"memories": [{"text": "User is vegan.", "type": "profile", "private": false}, {"text": "User has asthma.", "type": "profile", "private": true}]}',
      ),
    ).toEqual([
      fact('User is vegan.'),
      fact('User has asthma.', {sensitive: 'other'}),
    ]);
  });

  it("reads mem0's plain list and tolerates text around the JSON", () => {
    expect(
      texts(
        parseExtraction(
          'Sure!\n{"facts": ["Name is John", "Is a software engineer"]}\nDone.',
        ),
      ),
    ).toEqual(['Name is John', 'Is a software engineer']);
    expect(parseExtraction('[{"fact": "Likes tea"}]')).toEqual([
      fact('Likes tea', {kind: 'context'}),
    ]);
  });

  it('returns nothing for rubbish', () => {
    expect(parseExtraction('I could not find anything.')).toEqual([]);
    expect(parseExtraction('{"memories": "none"}')).toEqual([]);
    expect(
      parseExtraction('{"memories": [{"type": "profile"}, 7, ""]}'),
    ).toEqual([]);
    expect(parseJsonLoose('{"a": 1} trailing }')).toEqual({a: 1});
    expect(parseJsonLoose('nothing')).toBeNull();
  });
});

describe('screenFacts', () => {
  it('drops private facts the user did not ask to save', () => {
    const kept = screenFacts(
      [
        fact('User was diagnosed with type 2 diabetes.'),
        fact('User is Muslim.', {sensitive: 'other'}),
        fact('User loves cooking Persian food.'),
      ],
      {turns: ["I'm Muslim, diabetic, and I love cooking Persian food."]},
    );
    expect(texts(kept)).toEqual(['User loves cooking Persian food.']);
  });

  it('keeps a private fact the user asked to remember, and marks it', () => {
    const kept = screenFacts([fact('User has celiac disease.')], {
      turns: ['Please remember that I have celiac disease, so no gluten.'],
    });
    expect(kept).toEqual([
      fact('User has celiac disease.', {explicit: true, sensitive: null}),
    ]);
    const health = screenFacts([fact('User has asthma.')], {
      turns: ['Remember that I have asthma.'],
    });
    expect(health).toEqual([
      fact('User has asthma.', {explicit: true, sensitive: 'health'}),
    ]);
  });

  it('does not let a remember request cover an unrelated private fact', () => {
    const kept = screenFacts(
      [fact('User is vegetarian.'), fact('User takes antidepressants.')],
      {
        turns: [
          'Remember that I am vegetarian.',
          'Unrelated: I started antidepressants, is coffee still ok?',
        ],
      },
    );
    expect(kept).toEqual([fact('User is vegetarian.', {explicit: true})]);
  });

  it('keeps private facts when the setting allows it', () => {
    const kept = screenFacts([fact('User is gay.')], {
      turns: ["I'm gay."],
      includeSensitive: true,
    });
    expect(kept).toEqual([fact('User is gay.', {sensitive: 'sexuality'})]);
  });

  it('drops requests, dated one-offs and lines about the chat', () => {
    const kept = screenFacts(
      [
        fact('User wants a polite email to their landlord.'),
        fact('User needs dinner ideas for the week.'),
        fact('User asked what A1C means.'),
        fact('User has a fluid dynamics exam on Friday.'),
        fact('User is tired today.'),
        fact('User is tired and only got about four hours of sleep.'),
        fact('User is currently bored.'),
        fact("User said 'hey'"),
        fact('Assistant suggested a curry.'),
        fact('Is the user vegetarian?'),
        fact('User wants to become a pilot.'),
        fact('User is starting as a data analyst on Monday.'),
        fact('User studies mechanical engineering.'),
      ],
      {turns: ['…'], maxFacts: 20},
    );
    expect(texts(kept)).toEqual([
      'User wants to become a pilot.',
      'User is starting as a data analyst on Monday.',
      'User studies mechanical engineering.',
    ]);
  });

  it('cuts the request or the dated part out of a mixed sentence', () => {
    expect(
      trimFact(
        'User wants help planning a workout for three days and mentions a bad left knee, so avoid jumping exercises.',
      ),
    ).toBe('User mentions a bad left knee, so avoid jumping exercises.');
    expect(
      trimFact(
        'User has a dog named Pepper who is a border collie and turned five today.',
      ),
    ).toBe('User has a dog named Pepper who is a border collie.');
    expect(
      trimFact(
        'User loves cooking Persian food and plans a dinner party for 8 people next Friday.',
      ),
    ).toBe('User loves cooking Persian food.');
    // A lasting fact with a date in it is kept whole.
    const job =
      'User quit their job as a barista and started a new role: junior data analyst at an insurer on Monday.';
    expect(trimFact(job)).toBe(job);
    // Lists and ordinary sentences are left alone.
    expect(trimFact('User has two dogs, Rex and Bo.')).toBe(
      'User has two dogs, Rex and Bo.',
    );
    expect(trimFact('User wants a polite email, so keep it short.')).toBeNull();
    expect(
      trimFact(
        'User wants five phrases for a bank visit in Portuguese and Japanese.',
      ),
    ).toBeNull();
    expect(
      trimFact('User is tired and only got four hours of sleep.'),
    ).toBeNull();
  });

  it('ignores the private flag of a model that sets it loosely', async () => {
    const answer =
      '{"memories": [{"text": "User is a software developer in Toronto.", "type": "profile", "private": true}, {"text": "User is gay.", "type": "profile", "private": true}]}';
    const turns = ["I'm gay and a software developer in Toronto."];
    const lfm3 = await extractFacts({
      engine: createScriptedEngine(() => answer),
      family: 'lfm3',
      turns,
    });
    expect(texts(lfm3.facts)).toEqual([
      'User is a software developer in Toronto.',
    ]);
    const gemma = await extractFacts({
      engine: createScriptedEngine(() => answer),
      family: 'gemma4',
      turns,
    });
    expect(gemma.facts).toEqual([]);
  });

  it('drops a fact copied from the prompt examples unless the user said it', () => {
    const leaked = EXTRACTION_EXAMPLES.flatMap(example =>
      example.memories.map(memory => fact(memory.text)),
    );
    expect(
      screenFacts([...leaked, fact('User has a beagle called Biscuit.')], {
        turns: ['My dog Biscuit, a beagle, chews the sofa.'],
        maxFacts: 20,
        includeSensitive: true,
      }).map(f => f.text),
    ).toEqual(['User has a beagle called Biscuit.']);
    // The same sentence is kept when it is true of this user.
    expect(
      texts(
        screenFacts([fact('User does pottery.')], {
          turns: ['I do pottery on Fridays.'],
        }),
      ),
    ).toEqual(['User does pottery.']);
  });

  it('removes repeats and caps the list', () => {
    const many = Array.from({length: 9}, (_, i) =>
      fact(`User likes hobby ${i}`),
    );
    expect(
      screenFacts(
        [fact('User is vegan.'), fact('The user is vegan'), ...many],
        {
          turns: ['…'],
        },
      ),
    ).toHaveLength(5);
    expect(
      texts(
        screenFacts([fact('User is vegan.'), fact('The user is vegan')], {
          turns: ['…'],
        }),
      ),
    ).toEqual(['User is vegan.']);
  });
});

describe('extractFacts', () => {
  it('asks once, under a schema, with thinking off', async () => {
    const engine = createScriptedEngine(
      () =>
        '{"memories": [{"text": "User is a nurse.", "type": "profile", "private": false}, {"text": "User has diabetes.", "type": "profile", "private": true}]}',
    );
    const result = await extractFacts({
      engine,
      family: 'gemma4',
      turns: ["I'm a nurse with diabetes. How do I plan night shifts?"],
      known: ['User lives in Leeds.'],
    });
    expect(result.ok).toBe(true);
    expect(texts(result.raw)).toEqual([
      'User is a nurse.',
      'User has diabetes.',
    ]);
    expect(texts(result.facts)).toEqual(['User is a nurse.']);
    expect(engine.calls).toHaveLength(1);
    const call = engine.calls[0];
    expect(call.system).toBe(EXTRACTION_SYSTEM_PROMPT);
    expect(call.last).toBe(
      "Already saved:\n- User lives in Leeds.\nUser messages:\n1. I'm a nurse with diabetes. How do I plan night shifts?",
    );
    expect(call.params.response_format.type).toBe('json_schema');
    expect(call.params.temperature).toBe(0);
    expect(call.params.enable_thinking).toBe(false);
  });

  it('makes no call when there is nothing to read', async () => {
    const engine = createScriptedEngine(() => '{}');
    expect(await extractFacts({engine, turns: ['```js\nfoo()\n```']})).toEqual({
      ok: true,
      facts: [],
      raw: [],
    });
    expect(engine.calls).toHaveLength(0);
  });

  it('reports a failed call instead of throwing', async () => {
    const engine = createScriptedEngine(() => {
      throw new Error('context lost');
    });
    expect(await extractFacts({engine, turns: ['I live in Rome.']})).toEqual({
      ok: false,
      facts: [],
      raw: [],
    });
  });

  it('builds a numbered list of the user turns', () => {
    const messages = buildExtractionMessages(['first', 'second']);
    expect(messages[1].content).toBe('User messages:\n1. first\n2. second');
  });

  it('gives examples to Gemma only: LFM3 copies them into its answer', async () => {
    expect(extractionStyleFor('gemma4')).toBe('examples');
    expect(extractionStyleFor('lfm3')).toBe('rules');
    expect(extractionStyleFor(undefined)).toBe('rules');
    expect(EXTRACTION_SYSTEM_PROMPT.startsWith(EXTRACTION_RULES)).toBe(true);
    expect(EXTRACTION_SYSTEM_PROMPT).toContain('User does pottery.');
    expect(EXTRACTION_RULES).not.toContain('pottery');
    const engine = createScriptedEngine(() => '{"memories": []}');
    await extractFacts({engine, family: 'lfm3', turns: ['I live in Rome.']});
    expect(engine.calls[0].system).toBe(EXTRACTION_RULES);
  });
});
