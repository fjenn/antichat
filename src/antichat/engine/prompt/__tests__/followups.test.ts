import {createFakeEngine} from '../../context/__tests__/support/fakeEngine';
import {
  FOLLOWUP_MAX_CHARS,
  FOLLOWUP_SYSTEM_PROMPT,
  followUpsAllowed,
  generateFollowUps,
  parseFollowUps,
} from '../followups';

describe('parseFollowUps', () => {
  it('reads the JSON object form', () => {
    expect(
      parseFollowUps(
        '{"suggestions": ["What about wool carpets?", "Does salt help?", "How long should I wait?"]}',
      ),
    ).toEqual([
      'What about wool carpets?',
      'Does salt help?',
      'How long should I wait?',
    ]);
  });

  it('reads a bare array, fenced JSON and numbered lines', () => {
    expect(
      parseFollowUps('["One more idea?", "And another one?"]'),
    ).toHaveLength(2);
    expect(
      parseFollowUps(
        '```json\n{"suggestions":["Give an example","Explain it simply"]}\n```',
      ),
    ).toEqual(['Give an example', 'Explain it simply']);
    expect(
      parseFollowUps(
        '1. "Give an example"\n2) Explain it simply\n- What should I avoid?',
      ),
    ).toEqual(['Give an example', 'Explain it simply', 'What should I avoid?']);
  });

  it('drops duplicates, echoes of the question, markup and long items', () => {
    const raw = JSON.stringify({
      suggestions: [
        'How do I cook rice?',
        'how do i cook rice',
        'Which rice is best?',
        'Which rice is best?!',
        '<tool_call>',
        'x'.repeat(FOLLOWUP_MAX_CHARS + 1),
        'ok',
        'How much water do I need?',
        'A fourth one that is fine',
      ],
    });
    expect(parseFollowUps(raw, 'How do I cook rice?')).toEqual([
      'Which rice is best?',
      'How much water do I need?',
      'A fourth one that is fine',
    ]);
  });

  it("drops offers in the assistant's voice", () => {
    const raw = JSON.stringify({
      suggestions: [
        'Would you like a vegan version?',
        'Should I explain the steps again?',
        'Do you need more details?',
        'Can I use cream instead?',
        'How long does the pasta cook?',
      ],
    });
    expect(parseFollowUps(raw, 'Give me a carbonara recipe please')).toEqual([
      'Can I use cream instead?',
      'How long does the pasta cook?',
    ]);
  });

  it('keeps suggestions in the user language and script', () => {
    const german = 'Wie koche ich ein weiches Ei, ohne dass es platzt?';
    expect(
      parseFollowUps(
        '["What is the best way to serve it?", "Wie lange dauert es bei großen Eiern?", "Kann ich das Ei auch im Ofen machen?"]',
        german,
      ),
    ).toEqual([
      'Wie lange dauert es bei großen Eiern?',
      'Kann ich das Ei auch im Ofen machen?',
    ]);
    expect(
      parseFollowUps(
        '["How do I type faster?", "Какие упражнения лучше?"]',
        'Как научиться быстро печатать?',
      ),
    ).toEqual(['Какие упражнения лучше?']);
  });

  it('returns nothing for prose', () => {
    expect(parseFollowUps('I think you could ask about rice.')).toEqual([]);
    expect(parseFollowUps('')).toEqual([]);
  });
});

describe('generateFollowUps', () => {
  it('asks with a JSON schema and thinking off', async () => {
    const engine = createFakeEngine();
    const items = await generateFollowUps({
      engine,
      userMessage: 'How do I cook rice?',
      assistantReply: 'Rinse it, then simmer for 12 minutes.',
    });
    expect(items).toHaveLength(3);
    const call = engine.calls[0];
    expect(call.kind).toBe('followups');
    expect(call.messages[0].content).toBe(FOLLOWUP_SYSTEM_PROMPT);
    expect(call.params.enable_thinking).toBe(false);
    expect((call.params.response_format as {type: string}).type).toBe(
      'json_schema',
    );
  });

  it('returns nothing without a reply, on failure, or with one usable item', async () => {
    const engine = createFakeEngine();
    expect(
      await generateFollowUps({engine, userMessage: 'Hi', assistantReply: ''}),
    ).toEqual([]);
    engine.completion = jest.fn().mockResolvedValue({
      text: '',
      content: '{"suggestions":["Only one here"]}',
    });
    expect(
      await generateFollowUps({
        engine,
        userMessage: 'Hi there',
        assistantReply: 'Hello',
      }),
    ).toEqual([]);
    engine.completion = jest.fn().mockRejectedValue(new Error('x'));
    expect(
      await generateFollowUps({
        engine,
        userMessage: 'Hi there',
        assistantReply: 'Hello',
      }),
    ).toEqual([]);
  });

  it('is limited to device classes C and D', () => {
    expect(['A', 'B', 'C', 'D'].map(c => followUpsAllowed(c as 'A'))).toEqual([
      false,
      false,
      true,
      true,
    ]);
  });
});
