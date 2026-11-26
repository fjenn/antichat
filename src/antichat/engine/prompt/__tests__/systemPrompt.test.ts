import {estimateTokens} from '../../context/tokenCounter';
import {detectModelFamily, familyProfile, samplingFor} from '../modelFamily';
import {
  DEFAULT_PERSONALIZATION,
  PERSONALIZATION_LIMITS,
  USER_TEXT_BUDGET,
  getPersonalization,
  loadPersonalization,
  personalizationBlocks,
  renderStyle,
  resetPersonalization,
  setPersonalization,
  subscribePersonalization,
} from '../personalization';
import {
  BASE_IDENTITY,
  TOOL_USE_CLAUSE,
  buildSystemBlocks,
  buildSystemPrompt,
  dateLine,
  needsClock,
  timeLine,
} from '../systemPrompt';
import {
  thinkingBudgetFor,
  thinkingParams,
  thinkingToggleBreaksCache,
} from '../thinking';

jest.mock('@react-native-async-storage/async-storage', () => {
  const data = new Map<string, string>();
  return {
    __esModule: true,
    default: {
      getItem: jest.fn(async (key: string) => data.get(key) ?? null),
      setItem: jest.fn(async (key: string, value: string) => {
        data.set(key, value);
      }),
      removeItem: jest.fn(async (key: string) => {
        data.delete(key);
      }),
    },
  };
});

const now = new Date(2026, 10, 24, 14, 5);

describe('system prompt', () => {
  it('is short: the base fits the 150–300 token rule for class A', () => {
    const prompt = buildSystemPrompt({now});
    expect(estimateTokens(prompt)).toBeLessThan(300);
    expect(prompt.startsWith(BASE_IDENTITY)).toBe(true);
  });

  it('puts the date last and only at day granularity', () => {
    const prompt = buildSystemPrompt({now, timeZone: 'Europe/Vienna'});
    expect(
      prompt.endsWith(
        'Current date: 2026-11-24 (Tuesday), time zone Europe/Vienna.',
      ),
    ).toBe(true);
    expect(prompt).not.toContain('14:05');
    const later = buildSystemPrompt({
      now: new Date(2026, 10, 24, 23, 59),
      timeZone: 'Europe/Vienna',
    });
    expect(later).toBe(prompt);
    expect(dateLine(new Date(2026, 0, 3))).toBe(
      'Current date: 2026-01-03 (Saturday).',
    );
    expect(timeLine(now)).toBe('Current local time: 14:05.');
  });

  it('keeps the stable part byte-identical when the day changes', () => {
    const today = buildSystemPrompt({now});
    const tomorrow = buildSystemPrompt({now: new Date(2026, 10, 25, 9, 0)});
    const stable = today.slice(0, today.indexOf('Current date:'));
    expect(tomorrow.startsWith(stable)).toBe(true);
    expect(tomorrow).not.toBe(today);
  });

  it('adds the tool clause only with tools, and the cutoff only when known', () => {
    expect(buildSystemPrompt({now})).not.toContain(TOOL_USE_CLAUSE);
    expect(buildSystemPrompt({now, hasTools: true})).toContain(TOOL_USE_CLAUSE);
    expect(buildSystemPrompt({now, knowledgeCutoff: 'January 2026'})).toContain(
      'Your knowledge ends around January 2026',
    );
  });

  it('orders blocks: base, style, profile, instructions, tools, then date', () => {
    const blocks = buildSystemBlocks({
      now,
      hasTools: true,
      personalization: {
        ...DEFAULT_PERSONALIZATION,
        preset: 'friendly',
        nickname: 'Marisol',
        customInstructions: 'Answer in bullet points.',
      },
    });
    const stable = blocks
      .filter(b => b.slot === 'stable')
      .sort((a, b) => (a.order ?? 0) - (b.order ?? 0));
    expect(stable.map(b => b.id)).toEqual([
      'base',
      'style',
      'about-user',
      'custom-instructions',
      'tool-use',
    ]);
    expect(blocks.filter(b => b.slot === 'session').map(b => b.id)).toEqual([
      'date',
    ]);
  });

  it('detects messages that need the clock, in several languages', () => {
    for (const text of [
      'What time is it?',
      'Wie spät ist es?',
      '¿Qué hora es?',
      'Quelle heure est-il ?',
      '今何時？',
      'How long until 6 pm?',
    ]) {
      expect(needsClock(text)).toBe(true);
    }
    for (const text of [
      'Write a poem about cats',
      'Explain recursion',
      'Erkläre mir Photosynthese',
    ]) {
      expect(needsClock(text)).toBe(false);
    }
  });
});

describe('personalisation', () => {
  beforeEach(() => resetPersonalization());

  it('adds nothing by default or when switched off', () => {
    expect(personalizationBlocks(DEFAULT_PERSONALIZATION)).toEqual([]);
    expect(personalizationBlocks(null)).toEqual([]);
    expect(
      personalizationBlocks({
        ...DEFAULT_PERSONALIZATION,
        enabled: false,
        preset: 'cynical',
        nickname: 'X',
      }),
    ).toEqual([]);
  });

  it('renders the preset and one sentence per moved dial', () => {
    expect(
      renderStyle({
        ...DEFAULT_PERSONALIZATION,
        preset: 'efficient',
        warmth: 'less',
        emoji: 'less',
        headersAndLists: 'more',
      }),
    ).toBe(
      'Style: efficient. Give the shortest answer that fully helps, in plain words: no greeting, no intro sentence, no closing line, no filler. Be neutral and matter-of-fact: no sympathy, reassurance or encouragement. Structure every answer with short Markdown headers (##) and bulleted lists. Never use emoji.',
    );
    expect(renderStyle({...DEFAULT_PERSONALIZATION, enthusiasm: 'more'})).toBe(
      'Be enthusiastic and upbeat: show excitement about the topic, with an exclamation mark or two.',
    );
  });

  it('has all seven presets', () => {
    for (const preset of [
      'default',
      'professional',
      'friendly',
      'candid',
      'quirky',
      'efficient',
      'cynical',
    ] as const) {
      const style = renderStyle({...DEFAULT_PERSONALIZATION, preset});
      expect(style === '').toBe(preset === 'default');
    }
  });

  it('frames the profile as rarely relevant', () => {
    const [about] = personalizationBlocks({
      ...DEFAULT_PERSONALIZATION,
      nickname: 'Marisol',
      occupation: 'Nurse',
      aboutYou: 'I live in Graz and have a beagle.',
    });
    expect(about.text).toBe(
      '# About the user\nThe user wrote this profile for all their chats, so it is not relevant to most requests. Use it only when it clearly helps, and do not mention it otherwise.\nName: Marisol\nOccupation: Nurse\nI live in Graz and have a beagle.',
    );
  });

  it('caps user text by device class (about 500 characters on class A)', () => {
    const settings = {
      ...DEFAULT_PERSONALIZATION,
      aboutYou: 'about '.repeat(250),
      customInstructions: 'rule '.repeat(300),
    };
    for (const deviceClass of ['A', 'B', 'C', 'D'] as const) {
      const text = personalizationBlocks(settings, deviceClass)
        .map(b =>
          b.text
            .split('\n')
            .slice(b.id === 'about-user' ? 2 : 1)
            .join('\n'),
        )
        .join('');
      expect(text.length).toBeLessThanOrEqual(
        USER_TEXT_BUDGET[deviceClass] + 8,
      );
    }
    const a = personalizationBlocks(settings, 'A')
      .map(b => b.text)
      .join('\n');
    expect(a.length).toBeLessThan(800);
  });

  it('stores, clamps, notifies and reloads settings', async () => {
    const seen: string[] = [];
    const stop = subscribePersonalization(s => seen.push(s.preset));
    setPersonalization({preset: 'quirky', nickname: 'n'.repeat(80)});
    expect(getPersonalization().nickname).toHaveLength(
      PERSONALIZATION_LIMITS.nickname,
    );
    setPersonalization({preset: 'nope' as 'default'});
    expect(getPersonalization().preset).toBe('default');
    stop();
    setPersonalization({preset: 'candid'});
    expect(seen).toEqual(['quirky', 'default']);
    resetPersonalization();
    expect((await loadPersonalization()).preset).toBe('candid');
  });
});

describe('model families and thinking', () => {
  it('detects families from names and templates', () => {
    expect(detectModelFamily({name: 'gemma-4-E2B-it-qat-UD-Q4_K_XL'})).toBe(
      'gemma4',
    );
    expect(detectModelFamily({filename: 'Qwen3.5-2B-Q4_K_M.gguf'})).toBe(
      'qwen35',
    );
    expect(detectModelFamily({id: 'LiquidAI/LFM3-1.7B-GGUF'})).toBe('lfm3');
    expect(detectModelFamily({name: 'SmolLM2-360M'})).toBe('generic');
    expect(detectModelFamily({chatTemplate: "{{- '<|turn>system' }}"})).toBe(
      'gemma4',
    );
    expect(detectModelFamily({chatTemplate: '<additional_tools>'})).toBe(
      'lfm3',
    );
    expect(
      detectModelFamily({chatTemplate: '<|im_start|> enable_thinking'}),
    ).toBe('qwen35');
    expect(detectModelFamily(null)).toBe('generic');
  });

  it('records the template facts that matter for caching', () => {
    expect(familyProfile('qwen35').toolsBeforeSystem).toBe(true);
    expect(familyProfile('gemma4').toolsBeforeSystem).toBe(false);
    expect(familyProfile('lfm3').thinkingDefault).toBe(true);
    expect(thinkingToggleBreaksCache('gemma4')).toBe(true);
    expect(thinkingToggleBreaksCache('qwen35')).toBe(false);
    expect(samplingFor('qwen35', false)).toEqual({
      temperature: 0.7,
      top_p: 0.8,
      top_k: 20,
    });
    expect(samplingFor('generic', true)).toEqual({});
  });

  it('always sends the thinking switch explicitly', () => {
    expect(thinkingParams({family: 'lfm3', enabled: false})).toEqual({
      enable_thinking: false,
      reasoning_format: 'auto',
      chat_template_kwargs: {enable_thinking: false},
    });
    expect(
      thinkingParams({family: 'qwen35', enabled: true, budgetTokens: 384}),
    ).toMatchObject({
      enable_thinking: true,
      chat_template_kwargs: {enable_thinking: true},
      thinking_budget_tokens: 384,
    });
    expect([4096, 8192, 32768].map(thinkingBudgetFor)).toEqual([
      384, 768, 1536,
    ]);
  });
});
