/**
 * Chat sanity set C1-C10 from docs/research/03-spike-protocol.md (step 3).
 * Answers are stored for manual 0-2 scoring; nothing is scored on the device.
 */
export type ChatCase = {
  id: string;
  looksFor: string;
  /** One or more user turns; the model answers each in order. */
  turns: string[];
};

// The protocol asks for a fixed 1,500-word article "in the plan file", which
// was never written. This fixed, invented ~650-word text stands in for it; all
// facts are made up, so any detail not in the text is an invention.
export const C10_ARTICLE = `Harbour town of Velden switches its ferry fleet to batteries

VELDEN — After eleven years of planning, the harbour town of Velden retired the last of its diesel ferries on Monday and replaced the fleet with four battery-electric vessels. The town council says the switch will cut the ferry service's fuel bill by about 60 percent and remove roughly 2,900 tonnes of carbon dioxide a year from the harbour.

The four new ferries, named Alba, Brisa, Corvo and Duna, were built at the Marholm shipyard for a total of 46 million euros. Each carries 180 passengers and 24 bicycles, but no cars. The old diesel boats carried 12 cars each, and the decision to drop car transport was the most contested part of the plan. A local referendum in 2023 approved it by 54 to 46 percent, after the council promised a park-and-ride site with 400 spaces on the mainland side.

The crossing between the mainland pier and the island district of Oster takes 14 minutes, two minutes longer than before, because the electric ferries cruise at nine knots instead of eleven. Ferries now leave every 10 minutes at peak times instead of every 20, which the operator says more than makes up for the slower crossing. Each boat recharges for four minutes at an automatic charging arm while passengers board. The batteries hold 1,100 kilowatt-hours and are expected to last ten years before they need replacing.

Not everything went to plan. The charging arm on the Oster side failed twice during trials in March when salt spray caused a sensor fault, and one ferry, Corvo, was delivered five months late after a supplier of battery housings went bankrupt. The project's budget grew from 38 million to 46 million euros, with the regional government covering 15 million and the town borrowing the rest over 20 years.

Harbour master Ilse Brandt said the trials also showed an unexpected benefit. "The boats are so quiet that the seals have come back to the inner harbour," she said. "We counted 30 last week. Ten years ago we counted none." She added that crews needed about six weeks of retraining, mostly on emergency procedures for battery fires, and that no jobs were lost in the change.

Fishermen are less pleased. The fishing cooperative, which represents 35 boats, complains that the new charging station takes up the quay space where its members used to unload. Its chairman, Tomas Reuter, said the cooperative had been offered a new unloading quay 300 metres further out, but that the site has no ice plant. The council says an ice plant will be built there by next summer at a cost of 1.2 million euros.

Shop owners on Oster have mixed views. A bakery owner said more frequent ferries had already brought more day visitors, while the owner of the island's only hardware shop said deliveries had become harder because vans can no longer cross. Goods now come over on a small cargo barge that runs twice a day, at 6:00 and at 15:00.

Ticket prices stay the same for now: 2.40 euros for a single crossing and 38 euros for a monthly pass. The operator has said prices will be reviewed in two years, once the real running costs are known. Children under 12 travel free, as before.

Two of the old diesel ferries have been sold to an operator in the Baltic; the third will become a floating restaurant moored at the mainland pier. The council plans to use what it has learned for its next project, electrifying the town's 18 buses by 2030. Mayor Jonas Akkerman called the ferry launch "the day Velden stopped talking about the future and started riding on it", and said he would be on the first morning crossing with a bicycle.`;

export const CHAT_CASES: ChatCase[] = [
  {
    id: 'C1',
    looksFor: 'clarity, length control',
    turns: ['Explain how a heat pump works to a 12-year-old in 5 sentences.'],
  },
  {
    id: 'C2',
    looksFor: '2 h 15 min',
    turns: [
      'A train leaves at 14:10 and arrives at 16:45 after a 20-minute stop. How long was it moving?',
    ],
  },
  {
    id: 'C3',
    looksFor: 'tone, no added content',
    turns: [
      'Rewrite this to sound polite and brief: "send me the file now, I\'ve asked three times"',
    ],
  },
  {
    id: 'C4',
    looksFor: 'correct German',
    turns: [
      'Schreibe eine kurze Absage für eine Einladung zum Abendessen am Samstag.',
    ],
  },
  {
    id: 'C5',
    looksFor: 'valid table',
    turns: [
      'Give me a 3-day Lisbon itinerary as a markdown table with columns Day, Morning, Afternoon, Evening.',
    ],
  },
  {
    id: 'C6',
    looksFor: 'correct code block',
    turns: [
      'Write a JavaScript function that removes duplicates from an array of objects by `id`.',
    ],
  },
  {
    id: 'C7',
    looksFor: 'admits it cannot know, does not invent',
    turns: ['What happened in the news yesterday?'],
  },
  {
    id: 'C8',
    looksFor: 'coherence over length',
    turns: [
      'Write a 300-word story about a lighthouse keeper who finds a message in a bottle.',
    ],
  },
  {
    id: 'C9',
    looksFor: 'uses both facts',
    turns: [
      "My sister's name is Jana and she is allergic to nuts.",
      'Suggest a birthday cake for her.',
    ],
  },
  {
    id: 'C10',
    looksFor: 'faithful, no inventions',
    turns: [`Summarise this article in 5 bullets.\n\n${C10_ARTICLE}`],
  },
];

export const C1_PROMPT = CHAT_CASES[0].turns[0];
export const C8_PROMPT = CHAT_CASES[7].turns[0];
