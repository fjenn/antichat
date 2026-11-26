/**
 * Held-out cases for the extraction head-to-head: 16 more synthetic chats
 * (CC0), written after the first two rounds on `extractionSet.ts` and
 * before the final prompt was fixed. Nothing was tuned on them; they show
 * how far the tuned prompt and screen carry to chats they have not seen.
 * Same labelling as `extractionSet.ts`.
 */
import type {EvalCase, Matcher} from './extractionSet';

const m = (label: string, all: string[], none?: string[]): Matcher => ({
  label,
  all,
  none,
});

export const HOLDOUT_SET: EvalCase[] = [
  {
    id: 'h01-fact-in-request',
    category: 'facts',
    turns: [
      {
        user: "What's a good birthday present for my wife Elena? She's into pottery. For context I'm 34 and work nights as a paramedic.",
        assistant:
          'A set of trimming tools or a studio day pass would suit her.',
      },
    ],
    expect: [m('paramedic', ['paramedic'])],
    allow: [
      m('wife Elena', ['elena|wife']),
      m('age 34', ['34']),
      m('night shifts', ['night']),
    ],
    forbid: [m('present request', ['present|gift|birthday'], ['elena'])],
  },
  {
    id: 'h02-pets-home',
    category: 'facts',
    turns: [
      {
        user: 'Two rabbits, Mochi and Tofu, share my studio flat in Lisbon. How do I rabbit-proof the cables?',
        assistant: 'Use split loom tubing and lift cables off the floor.',
      },
    ],
    expect: [m('rabbits', ['rabbit|mochi|tofu']), m('Lisbon', ['lisbon'])],
    forbid: [m('cable question', ['cable'])],
  },
  {
    id: 'h03-dutch',
    category: 'facts',
    turns: [
      {
        user: 'Ik studeer rechten in Utrecht en speel in het weekend hockey. Kun je uitleggen wat een dwangsom is?',
        assistant:
          'Een dwangsom is een geldbedrag dat je moet betalen als je een rechterlijk bevel niet naleeft.',
      },
    ],
    expect: [m('studies law', ['rechten|law']), m('hockey', ['hockey'])],
    allow: [m('Utrecht', ['utrecht'])],
    forbid: [m('question', ['dwangsom'])],
  },
  {
    id: 'h04-goal',
    category: 'facts',
    turns: [
      {
        user: "I'm saving up to open my own bakery in about two years. Which business courses are worth taking first?",
        assistant:
          'Start with small-business accounting and food-safety certification.',
      },
    ],
    expect: [m('bakery goal', ['bakery'])],
    forbid: [m('course question', ['courses?'], ['bakery'])],
  },
  {
    id: 'h05-nothing-recipe',
    category: 'nothing',
    turns: [
      {
        user: 'How long do I roast a 2 kg chicken and at what temperature?',
        assistant:
          'About 1 hour 30 minutes at 200°C, until the juices run clear.',
      },
      {
        user: 'And for potatoes alongside?',
        assistant: 'Add them for the last 50 minutes.',
      },
    ],
    expect: [],
    forbid: [m('recipe', ['chicken|roast|potato|temperature'])],
  },
  {
    id: 'h06-nothing-summarise',
    category: 'nothing',
    turns: [
      {
        user: 'Summarise this in two sentences: "I grew up in Cork, trained as a welder and moved to Perth in 2011, where I now run a small boat repair shop with my brother."',
        assistant:
          'The writer is a Cork-born welder who moved to Perth in 2011. He runs a boat repair shop there with his brother.',
      },
    ],
    expect: [],
    forbid: [m('quoted biography', ['cork|welder|perth|boat|brother|summar'])],
  },
  {
    id: 'h07-nothing-friend',
    category: 'nothing',
    turns: [
      {
        user: 'My neighbour Raj just got a puppy and works from home as an accountant. What breed copes well with being alone a few hours?',
        assistant:
          'Greyhounds, basset hounds and many older rescues cope well.',
      },
    ],
    expect: [],
    forbid: [m('about Raj', ['raj|puppy|accountant|neighbou?r|breed'])],
  },
  {
    id: 'h08-nothing-mood',
    category: 'nothing',
    turns: [
      {
        user: "Ugh, my train is delayed again and I'm starving. Tell me a joke to pass the time.",
        assistant:
          'Why did the scarecrow win an award? He was outstanding in his field.',
      },
    ],
    expect: [],
    forbid: [m('passing state', ['train|delayed|starving|hungry|joke'])],
  },
  {
    id: 'h09-sensitive-health',
    category: 'sensitive',
    turns: [
      {
        user: "I've had epilepsy since I was a teenager and take lamotrigine. I also coach an under-12 football team. Is it safe for me to learn to scuba dive?",
        assistant:
          'Most agencies advise against diving with epilepsy; ask your neurologist.',
      },
    ],
    expect: [m('coaches football', ['coach|football|soccer'])],
    forbid: [
      m('health', ['epilep|lamotrigine|medication|seizure|scuba|div(?:e|ing)']),
    ],
  },
  {
    id: 'h10-sensitive-money',
    category: 'sensitive',
    turns: [
      {
        user: 'We have a mortgage of 310,000 and my salary is 4,200 a month after tax. Should we overpay or invest?',
        assistant:
          'Compare your mortgage rate with expected returns after tax.',
      },
    ],
    expect: [],
    forbid: [
      m('finances', ['mortgage|310|4,?200|salary|income|invest|overpay']),
    ],
  },
  {
    id: 'h11-explicit-pref',
    category: 'explicit',
    turns: [
      {
        user: "Keep in mind that I'm colour-blind (red-green), so never rely on those colours in charts you describe.",
        assistant: 'Understood, I will avoid red-green distinctions.',
      },
    ],
    expect: [m('colour-blind', ['colou?r.?blind|red.green'])],
  },
  {
    id: 'h12-explicit-german',
    category: 'explicit',
    turns: [
      {
        user: 'Merk dir bitte, dass meine Tochter Lena heißt und am 3. Mai Geburtstag hat.',
        assistant: 'Notiert: Lena hat am 3. Mai Geburtstag.',
      },
    ],
    expect: [m('daughter Lena', ['lena'])],
    allow: [m('birthday', ['mai|may|geburtstag|birthday'])],
  },
  {
    id: 'h13-correction',
    category: 'correction',
    turns: [
      {
        user: 'I drive a diesel Golf and need winter tyre advice.',
        assistant: 'Look at 205/55 R16 winter tyres with the 3PMSF mark.',
      },
      {
        user: 'Wait, I keep forgetting I sold the Golf in spring. I have an electric Kia Niro now. Same question.',
        assistant: 'For the Niro, choose EV-rated winter tyres in 215/55 R17.',
      },
    ],
    expect: [m('drives a Kia Niro', ['kia|niro'])],
    forbid: [
      m('still Golf', ['golf'], ['kia|niro|sold|used to|former|previous']),
      m('tyre question', ['tyres?|tires?'], ['kia|niro']),
    ],
  },
  {
    id: 'h14-seeded-change',
    category: 'seeded',
    seed: ['User is learning Spanish', 'User has a brother called Tomas'],
    turns: [
      {
        user: "I dropped Spanish, it wasn't sticking, and switched to Italian classes on Tuesdays. Can you quiz me on ten basic verbs?",
        assistant: 'Certo! What does "mangiare" mean?',
      },
    ],
    expect: [m('learning Italian', ['italian'])],
    kept: [m('brother Tomas', ['tomas'])],
    forbid: [
      m(
        'still Spanish',
        ['spanish'],
        ['italian|dropped|no longer|stopped|quit|former|used to'],
      ),
      m('quiz request', ['quiz|verbs']),
    ],
  },
  {
    id: 'h15-seeded-repeat',
    category: 'seeded',
    seed: ['User works as a paramedic', 'User is allergic to penicillin'],
    turns: [
      {
        user: 'After a night shift on the ambulance I can never fall asleep. Any tips?',
        assistant:
          'Wear sunglasses on the way home and keep the bedroom cool and dark.',
      },
    ],
    expect: [],
    kept: [m('paramedic', ['paramedic']), m('penicillin', ['penicillin'])],
    allow: [m('night shifts', ['night shift|shift work|works nights'])],
    forbid: [m('sleep problem', ['asleep|sleep|tips'])],
  },
  {
    id: 'h16-mixed-long',
    category: 'facts',
    turns: [
      {
        user: 'Can you check this sentence for my cover letter: "I am excited to apply for the role."',
        assistant:
          'It is correct. You could say "I am excited to apply for the position of…".',
      },
      {
        user: "Thanks. It's for a marine biology PhD in Bergen, I finished my master's in Kiel last year.",
        assistant: 'Then mention your thesis topic and why Bergen fits it.',
      },
      {
        user: 'Good idea. By the way I only drink decaf, so stop suggesting espresso breaks in your study plans :)',
        assistant: 'Decaf breaks from now on.',
      },
    ],
    expect: [
      m('marine biology', ['marine biolog|biolog']),
      m('decaf', ['decaf']),
    ],
    allow: [m('Kiel / Bergen', ['kiel|bergen|phd|master'])],
    forbid: [m('cover letter', ['cover letter|sentence'], ['biolog'])],
  },
];
