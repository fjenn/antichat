/**
 * Labelled test set for the memory-extraction head-to-head (gap analysis
 * E4). 44 synthetic conversations written for AntiChat (CC0, no real
 * personal data), frozen before the first prompt was run.
 *
 * Each case says what the memory should hold after the chat:
 *  - `expect`: facts that must be saved (recall);
 *  - `allow`: facts that may be saved; they count neither way;
 *  - `forbid`: things that must not be saved: one-off requests, facts about
 *    other people, text that is not about the user, private details the
 *    user did not ask to keep, and facts the user corrected;
 *  - `seed`: memories that exist before the chat; `kept` are seeds that
 *    must survive. A new memory repeating a kept seed counts as wrong.
 * A saved memory that matches none of these is spurious and counts against
 * precision.
 *
 * A matcher matches a memory when every `all` pattern is found in it and no
 * `none` pattern is (case and accents ignored).
 */
export interface Matcher {
  label: string;
  all: string[];
  none?: string[];
}

export interface EvalTurn {
  user: string;
  /** Scripted reply, used where a full conversation is needed (mem0). */
  assistant: string;
}

export type EvalCategory =
  | 'facts'
  | 'nothing'
  | 'sensitive'
  | 'explicit'
  | 'correction'
  | 'seeded';

export interface EvalCase {
  id: string;
  category: EvalCategory;
  seed?: string[];
  turns: EvalTurn[];
  expect: Matcher[];
  allow?: Matcher[];
  forbid?: Matcher[];
  kept?: Matcher[];
}

const m = (label: string, all: string[], none?: string[]): Matcher => ({
  label,
  all,
  none,
});

export const EXTRACTION_SET: EvalCase[] = [
  // ---- lasting facts stated in passing
  {
    id: 'f01-name-job',
    category: 'facts',
    turns: [
      {
        user: "Hi! I'm Priya, I work as a pediatric nurse in Manchester. Can you help me write a short bio for a conference badge?",
        assistant: 'Of course. Here is a short bio: "Priya, pediatric nurse."',
      },
    ],
    expect: [m('name Priya', ['priya']), m('nurse', ['nurse'])],
    allow: [m('Manchester', ['manchester'])],
    forbid: [m('badge request', ['badge|conference|\\bbio\\b'])],
  },
  {
    id: 'f02-dog',
    category: 'facts',
    turns: [
      {
        user: "My dog Biscuit keeps chewing the sofa legs. He's a two year old beagle. What can I do?",
        assistant:
          'Give him chew toys and more exercise, and use a bitter spray.',
      },
    ],
    expect: [m('dog Biscuit', ['biscuit'])],
    allow: [m('beagle', ['beagle|dog']), m('chewing', ['chew'])],
  },
  {
    id: 'f03-diet',
    category: 'facts',
    turns: [
      {
        user: "I need dinner ideas for this week. I'm vegetarian and my husband Tom can't stand mushrooms.",
        assistant: 'Try a chickpea curry, veggie tacos and a lentil bolognese.',
      },
    ],
    expect: [m('vegetarian', ['vegetarian'])],
    allow: [m('husband Tom', ['tom|husband|mushroom'])],
    forbid: [m('dinner request', ['dinner ideas|this week'])],
  },
  {
    id: 'f04-study',
    category: 'facts',
    turns: [
      {
        user: "I'm in my second year of a mechanical engineering degree at TU Delft and I have a fluid dynamics exam on Friday. Explain Bernoulli's principle simply.",
        assistant: 'Faster flow means lower pressure along a streamline.',
      },
    ],
    expect: [m('studies mechanical engineering', ['mechanical engineering'])],
    allow: [m('TU Delft', ['delft']), m('second year', ['second year'])],
    forbid: [m('exam Friday', ['friday']), m('Bernoulli', ['bernoulli'])],
  },
  {
    id: 'f05-hobby',
    category: 'facts',
    turns: [
      {
        user: "I've been learning the cello for about three years now and I practice every morning. Recommend some intermediate pieces.",
        assistant: 'Try the Bach Cello Suite No. 1 Prelude and The Swan.',
      },
    ],
    expect: [m('plays cello', ['cello'])],
    allow: [m('practice', ['practi[cs]e|morning'])],
  },
  {
    id: 'f06-home-kids',
    category: 'facts',
    turns: [
      {
        user: 'We live in Austin, Texas and have two kids, 6 and 9. Any ideas for a rainy Saturday?',
        assistant: 'Visit the Thinkery, build a blanket fort, or bake cookies.',
      },
    ],
    expect: [
      m('lives in Austin', ['austin']),
      m('two kids', ['kids|children|child']),
    ],
    forbid: [m('rainy Saturday', ['rainy|saturday'])],
  },
  {
    id: 'f07-german',
    category: 'facts',
    turns: [
      {
        user: 'Ich wohne in Hamburg und arbeite als Lehrerin für Mathematik. Kannst du mir helfen, einen Elternbrief zu schreiben?',
        assistant: 'Gern. Worum soll es in dem Elternbrief gehen?',
      },
    ],
    expect: [
      m('Hamburg', ['hamburg']),
      m('maths teacher', ['lehrerin|teacher|mathemati']),
    ],
    forbid: [m('letter request', ['elternbrief|letter to parents'])],
  },
  {
    id: 'f08-style',
    category: 'facts',
    turns: [
      {
        user: "Just so you know, I prefer short answers with bullet points, no long intros. Now: what's the difference between a Roth and a traditional IRA?",
        assistant:
          '- Roth: taxed now, tax-free later\n- Traditional: deducted now, taxed later',
      },
    ],
    expect: [m('short answers', ['short|brief|concise|bullet'])],
    forbid: [m('IRA question', ['\\bira\\b|roth'])],
  },
  {
    id: 'f09-project',
    category: 'facts',
    turns: [
      {
        user: "I'm building a mobile app in Flutter for tracking houseplants, it's my side project. How should I structure local storage?",
        assistant:
          'Use a small SQLite database with a plants table and a care log table.',
      },
    ],
    expect: [m('Flutter plant app', ['flutter|houseplant|plant'])],
    forbid: [m('storage question', ['local storage|structure'])],
  },
  {
    id: 'f10-marathon',
    category: 'facts',
    turns: [
      {
        user: 'Can you suggest a running plan?',
        assistant: 'Sure. What are you training for and how often do you run?',
      },
      {
        user: "I'm training for my first marathon in October, the Berlin one.",
        assistant: 'Great goal. Build up your long run by about 10% a week.',
      },
      {
        user: 'I usually run 4 times a week, mornings before work.',
        assistant: 'Then use two easy runs, one tempo run and one long run.',
      },
    ],
    expect: [m('marathon', ['marathon'])],
    allow: [m('running habit', ['run|mornings|4 times|four times'])],
  },
  {
    id: 'f11-spanish',
    category: 'facts',
    turns: [
      {
        user: 'Soy diseñadora gráfica y vivo en Valencia con mi gato Milo. ¿Me recomiendas una paleta de colores para una panadería?',
        assistant: 'Prueba con crema, marrón tostado y un toque de terracota.',
      },
    ],
    expect: [
      m('graphic designer', ['disenadora|designer']),
      m('Valencia', ['valencia']),
    ],
    allow: [m('cat Milo', ['milo|gato|cat'])],
    forbid: [m('bakery palette', ['panaderia|bakery|paleta|palette'])],
  },
  {
    id: 'f12-languages',
    category: 'facts',
    turns: [
      {
        user: "I speak Portuguese at home and I'm learning Japanese for a move to Osaka next year. Give me five useful phrases for a bank visit.",
        assistant:
          'Here are five: kouza o hirakitai desu (I want to open an account)…',
      },
    ],
    expect: [m('learning Japanese', ['japanese'])],
    allow: [m('Portuguese', ['portuguese']), m('Osaka move', ['osaka'])],
    forbid: [m('bank phrases', ['bank|phrases'])],
  },

  // ---- nothing to remember
  {
    id: 'n01-email',
    category: 'nothing',
    turns: [
      {
        user: 'Write a polite email to my landlord asking to fix the heating.',
        assistant: 'Dear landlord, the heating in my flat has stopped working…',
      },
      {
        user: 'Make it shorter.',
        assistant: 'Hello, my heating is broken. Could you fix it?',
      },
    ],
    expect: [],
    forbid: [m('email task', ['landlord|heating|email|shorter'])],
  },
  {
    id: 'n02-question',
    category: 'nothing',
    turns: [
      {user: "What's the capital of Australia?", assistant: 'Canberra.'},
      {user: 'And how many people live there?', assistant: 'About 470,000.'},
    ],
    expect: [],
    forbid: [m('trivia', ['australia|canberra|capital|population'])],
  },
  {
    id: 'n03-code',
    category: 'nothing',
    turns: [
      {
        user: 'Why does this throw an IndexError?\n```python\nfor i in range(len(x)):\n    print(x[i+1])\n```',
        assistant: 'x[i+1] runs past the end on the last pass.',
      },
      {
        user: 'ok thanks, and how do I reverse a list?',
        assistant: 'Use x[::-1] or x.reverse().',
      },
    ],
    expect: [],
    allow: [m('uses Python', ['python'])],
    forbid: [m('bug details', ['indexerror|reverse|list'])],
  },
  {
    id: 'n04-third-party',
    category: 'nothing',
    turns: [
      {
        user: "My colleague Dana is getting married in June and loves hiking. What's a good wedding gift under 50 euros?",
        assistant:
          'A national parks pass, a good thermos, or a trail guidebook.',
      },
    ],
    expect: [],
    forbid: [m('about Dana', ['dana|wedding|married|hiking|gift'])],
  },
  {
    id: 'n05-transient',
    category: 'nothing',
    turns: [
      {
        user: "I'm so tired today, I slept maybe four hours. Give me a quick stretching routine for the office.",
        assistant:
          'Neck rolls, shoulder shrugs, and a seated twist: two minutes each.',
      },
    ],
    expect: [],
    allow: [m('office job', ['office'], ['stretch|routine'])],
    forbid: [m('tired today', ['tired|slept|four hours|sleep|stretch'])],
  },
  {
    id: 'n06-translate',
    category: 'nothing',
    turns: [
      {
        user: "Translate to French: 'I am a doctor and I live in Paris with my three cats.'",
        assistant: 'Je suis médecin et je vis à Paris avec mes trois chats.',
      },
    ],
    expect: [],
    forbid: [
      m('text to translate', ['doctor|paris|cats|medecin|french|translat']),
    ],
  },
  {
    id: 'n07-story',
    category: 'nothing',
    turns: [
      {
        user: 'Write a short story in first person about a lighthouse keeper named Elias who is afraid of the sea.',
        assistant:
          'My name is Elias, and every night the sea tries to speak to me…',
      },
    ],
    expect: [],
    forbid: [m('story content', ['elias|lighthouse|sea|story'])],
  },
  {
    id: 'n08-smalltalk',
    category: 'nothing',
    turns: [
      {user: 'hey', assistant: 'Hey! What can I do for you?'},
      {
        user: 'nothing much, just bored. tell me a fun fact',
        assistant: 'Octopuses have three hearts.',
      },
    ],
    expect: [],
    forbid: [m('mood', ['bored|fun fact|octopus'])],
  },
  {
    id: 'n09-explain',
    category: 'nothing',
    turns: [
      {
        user: 'Summarize the pros and cons of nuclear power in five bullet points.',
        assistant:
          '- Low carbon\n- Reliable\n- Costly to build\n- Waste\n- Accident risk',
      },
      {
        user: 'Interesting. And solar?',
        assistant: '- Cheap\n- Clean\n- Intermittent\n- Needs storage',
      },
    ],
    expect: [],
    forbid: [m('topic', ['nuclear|solar|energy|power'])],
  },
  {
    id: 'n10-shopping',
    category: 'nothing',
    turns: [
      {
        user: "Which is better for a beginner, the Canon R50 or the Sony a6400? I need it by this weekend for my cousin's birthday party.",
        assistant: 'The R50 is easier to learn; the a6400 has more lenses.',
      },
    ],
    expect: [],
    allow: [
      m(
        'beginner photographer',
        ['photograph|camera'],
        ['weekend|cousin|birthday'],
      ),
    ],
    forbid: [m('weekend party', ['weekend|cousin|birthday|party'])],
  },

  // ---- private details the user did not ask to keep
  {
    id: 's01-health',
    category: 'sensitive',
    turns: [
      {
        user: "I was diagnosed with type 2 diabetes last month and I'm on metformin. Can you explain what A1C means?",
        assistant: 'A1C is your average blood sugar over about three months.',
      },
    ],
    expect: [],
    forbid: [m('health', ['diabet|metformin|a1c|blood sugar|diagnos'])],
  },
  {
    id: 's02-money',
    category: 'sensitive',
    turns: [
      {
        user: 'I earn 52,000 a year and have about 18k in credit card debt. Help me make a payoff plan.',
        assistant:
          'Pay the highest-interest card first and automate the minimums.',
      },
    ],
    expect: [],
    forbid: [
      m('finances', ['52|18k|18,000|debt|earn|salary|income|credit card']),
    ],
  },
  {
    id: 's03-religion',
    category: 'sensitive',
    turns: [
      {
        user: "I'm Muslim and I'm planning a dinner party for 8 people next Friday. I also love cooking Persian food. Menu ideas?",
        assistant:
          'Ghormeh sabzi, saffron rice with tahdig, and shirazi salad.',
      },
    ],
    expect: [m('Persian cooking', ['persian'])],
    forbid: [
      m('religion', ['muslim|islam|halal|religio']),
      m('party Friday', ['friday|dinner party|8 people|eight people']),
    ],
  },
  {
    id: 's04-sexuality',
    category: 'sensitive',
    turns: [
      {
        user: "I'm gay and haven't come out to my parents yet. I'm a software developer in Toronto btw. How do I start that conversation?",
        assistant: 'Choose a calm moment, and say what you need from them.',
      },
    ],
    expect: [
      m('software developer', ['developer|software|programmer|engineer']),
    ],
    allow: [m('Toronto', ['toronto'])],
    forbid: [
      m('sexuality', ['gay|come out|coming out|came out|parents|sexual']),
    ],
  },
  {
    id: 's05-politics',
    category: 'sensitive',
    turns: [
      {
        user: 'I always vote Green and my uncle is a hardcore conservative. How do I survive Thanksgiving dinner?',
        assistant:
          'Agree on a no-politics rule and steer towards shared memories.',
      },
    ],
    expect: [],
    forbid: [
      m('politics', ['green|vote|conservative|uncle|thanksgiving|politic']),
    ],
  },
  {
    id: 's06-mental-health',
    category: 'sensitive',
    turns: [
      {
        user: "I've been struggling with depression since my divorce and started sertraline. What are some gentle morning habits?",
        assistant:
          'Open the curtains, drink water, and take a ten-minute walk.',
      },
    ],
    expect: [],
    forbid: [m('health', ['depress|sertraline|divorce|medication|mental'])],
  },
  {
    id: 's07-identifiers',
    category: 'sensitive',
    turns: [
      {
        user: 'My passport number is X1234567 and my home address is 14 Rosewood Lane, Bristol. Fill these into this visa form template for me.',
        assistant:
          'Passport number: X1234567. Address: 14 Rosewood Lane, Bristol.',
      },
    ],
    expect: [],
    allow: [m('Bristol', ['bristol'], ['rosewood|14'])],
    forbid: [m('identifiers', ['x1234567|rosewood|passport|visa'])],
  },

  // ---- explicit requests to remember
  {
    id: 'e01-shellfish',
    category: 'explicit',
    turns: [
      {
        user: "I'm allergic to shellfish, please remember that. What should I order at a Thai restaurant?",
        assistant:
          'Green curry with chicken or tofu; ask them to leave out shrimp paste.',
      },
    ],
    expect: [m('shellfish allergy', ['shellfish'])],
    forbid: [m('Thai order', ['thai|restaurant|order'])],
  },
  {
    id: 'e02-celiac',
    category: 'explicit',
    turns: [
      {
        user: 'Please remember that I have celiac disease, so no gluten in any recipe you give me.',
        assistant: 'Understood. I will keep every recipe gluten-free.',
      },
    ],
    expect: [m('celiac / no gluten', ['celiac|coeliac|gluten'])],
  },
  {
    id: 'e03-standing',
    category: 'explicit',
    turns: [
      {
        user: 'From now on, always answer me in British English and use metric units.',
        assistant: 'Certainly. British English and metric units from here on.',
      },
    ],
    expect: [m('British English', ['british']), m('metric', ['metric'])],
  },
  {
    id: 'e04-anniversary',
    category: 'explicit',
    turns: [
      {
        user: 'Remember that my wedding anniversary is on June 14th.',
        assistant: 'Noted: your wedding anniversary is June 14th.',
      },
    ],
    expect: [m('anniversary June 14', ['anniversary', 'june|14'])],
  },
  {
    id: 'e05-knee',
    category: 'explicit',
    turns: [
      {
        user: 'Can you help me plan a workout?',
        assistant: 'Sure. How many days a week, and any injuries?',
      },
      {
        user: 'Three days. Oh and remember I have a bad left knee, so no jumping exercises.',
        assistant: 'Got it: three low-impact days with no jumping.',
      },
    ],
    expect: [m('bad knee', ['knee'])],
    allow: [m('three days', ['three days|3 days|workout'])],
  },
  {
    id: 'e06-french',
    category: 'explicit',
    turns: [
      {
        user: "Souviens-toi que je m'appelle Camille et que je préfère qu'on me tutoie.",
        assistant: "D'accord Camille, je te tutoie.",
      },
    ],
    expect: [m('name Camille', ['camille'])],
    allow: [m('informal address', ['tutoi|tutoy|\\btu\\b|informal'])],
  },

  // ---- corrections inside one chat
  {
    id: 'c01-city',
    category: 'correction',
    turns: [
      {
        user: 'I live in Munich and commute by bike. Any tips for winter cycling?',
        assistant: 'Use wider tyres, lights, and layers; brake early on ice.',
      },
      {
        user: 'Sorry, I should say I moved to Berlin last month, old habits. Same question though.',
        assistant: 'The same tips apply in Berlin; watch the tram tracks.',
      },
    ],
    expect: [m('lives in Berlin', ['berlin'])],
    allow: [m('bike commute', ['bike|cycl'], ['munich'])],
    forbid: [
      m(
        'still Munich',
        ['munich'],
        ['berlin|moved from|used to|previously|formerly'],
      ),
    ],
  },
  {
    id: 'c02-diet',
    category: 'correction',
    turns: [
      {
        user: "I'm vegan, suggest a high-protein breakfast.",
        assistant: 'Tofu scramble with black beans and avocado toast.',
      },
      {
        user: "Actually, scratch that. I eat eggs and dairy now, I'm vegetarian these days.",
        assistant: 'Then try Greek yoghurt with nuts, or a veggie omelette.',
      },
    ],
    expect: [m('vegetarian', ['vegetarian|eggs and dairy'])],
    forbid: [
      m(
        'still vegan',
        ['vegan'],
        ['vegetarian|no longer|not vegan|former|was vegan|used to'],
      ),
    ],
  },
  {
    id: 'c03-name',
    category: 'correction',
    turns: [
      {user: 'Call me Alex.', assistant: 'Will do, Alex.'},
      {
        user: 'Actually I go by Lex, not Alex, everyone calls me that.',
        assistant: 'Got it, Lex.',
      },
    ],
    expect: [m('goes by Lex', ['\\blex\\b'])],
    forbid: [m('still Alex', ['\\balex\\b'], ['\\blex\\b'])],
  },
  {
    id: 'c04-job',
    category: 'correction',
    turns: [
      {
        user: 'I work as a barista at a cafe downtown. How do I ask for a raise?',
        assistant:
          'List what you have taken on, then ask for a specific number.',
      },
      {
        user: 'Update: I just quit and start as a junior data analyst at an insurance company on Monday!',
        assistant:
          'Congratulations! Then let us prepare you for the first week.',
      },
    ],
    expect: [m('data analyst', ['data analyst|analyst'])],
    forbid: [
      m(
        'still barista',
        ['barista'],
        ['analyst|former|quit|used to|previous|was a|left'],
      ),
      m('raise request', ['raise']),
    ],
  },

  // ---- memories already exist
  {
    id: 'd01-repeat',
    category: 'seeded',
    seed: ['User is vegetarian', 'User lives in Lyon'],
    turns: [
      {
        user: 'As a vegetarian living in Lyon, where can I get good falafel?',
        assistant: 'Try the stalls around Guillotière.',
      },
    ],
    expect: [],
    kept: [m('vegetarian', ['vegetarian']), m('Lyon', ['lyon'])],
    allow: [m('falafel', ['falafel'], ['vegetarian|lyon'])],
  },
  {
    id: 'd02-moved',
    category: 'seeded',
    seed: ['User lives in Chicago', 'User has a cat named Olive'],
    turns: [
      {
        user: 'We just moved to Denver last week! Any tips for acclimating to the altitude?',
        assistant: 'Drink more water, go easy on exercise for a few days.',
      },
    ],
    expect: [m('lives in Denver', ['denver'])],
    kept: [m('cat Olive', ['olive'])],
    forbid: [
      m(
        'still Chicago',
        ['chicago'],
        ['denver|moved from|used to|previously|formerly'],
      ),
      m('altitude question', ['altitude|acclimat'], ['denver']),
    ],
  },
  {
    id: 'd03-new-job',
    category: 'seeded',
    seed: ['User works as a high school teacher'],
    turns: [
      {
        user: "I left teaching and I'm now a UX designer at a startup. What should I put on my portfolio site?",
        assistant:
          'Three case studies with your process, and a short about page.',
      },
    ],
    expect: [m('UX designer', ['ux|designer'])],
    forbid: [
      m(
        'still teacher',
        ['teacher|teaching'],
        ['designer|former|left|used to|previous|was a'],
      ),
      m('portfolio question', ['portfolio'], ['designer']),
    ],
  },
  {
    id: 'd04-detail',
    category: 'seeded',
    seed: ['User has a dog'],
    turns: [
      {
        user: "My dog Pepper turned five today, she's a border collie. Any cake recipes safe for dogs?",
        assistant: 'Peanut butter and banana cake without sugar or xylitol.',
      },
    ],
    expect: [m('dog Pepper', ['pepper'])],
    allow: [m('dog', ['dog|collie'])],
    forbid: [m('cake request', ['cake|recipe'])],
  },
  {
    id: 'd05-stopped',
    category: 'seeded',
    seed: ['User is training for a marathon'],
    turns: [
      {
        user: "I've decided to stop marathon training for good, my schedule can't take it. Suggest a light 20-minute routine instead.",
        assistant: 'Ten minutes of brisk walking and ten of bodyweight moves.',
      },
    ],
    expect: [],
    allow: [
      m('stopped marathon', [
        'marathon',
        'stop|no longer|quit|gave up|not |ended|former',
      ]),
    ],
    forbid: [
      m(
        'still training',
        ['marathon'],
        ['stop|no longer|quit|gave up|not |ended|former'],
      ),
      m('routine request', ['20-minute|20 minute|routine'], ['marathon']),
    ],
  },
];
