import type {ChatMessage} from '../../prompt/types';
import {budgetFor} from '../budget';
import {
  OFFER_NEW_CHAT_AFTER,
  SUMMARY_BLOCK_HEADER,
  fingerprint,
  fitContext,
  renderSummaryBlock,
  type Summarizer,
} from '../fit';
import {emptyContextState, type ContextState} from '../summaryStore';
import {createEstimatingCounter, messageText} from '../tokenCounter';
import {
  HEAD_MARKER,
  MIDDLE_MARKER,
  applyInsertionLimits,
  truncateHead,
  truncateMiddle,
} from '../truncation';
import {filler} from './support/fakeEngine';

const counter = createEstimatingCounter();
const system: ChatMessage = {role: 'system', content: 'You are AntiChat.'};

const chat = (turns: number, words = 60): ChatMessage[] => {
  const out: ChatMessage[] = [];
  for (let i = 0; i < turns; i++) {
    out.push({role: 'user', content: `Question ${i}: ${filler(i, 12)}?`});
    out.push({
      role: 'assistant',
      content: `Answer ${i}: ${filler(i + 500, words)}.`,
    });
  }
  return out;
};

const summarize: Summarizer = async ({messages, previousFacts}) => ({
  facts: [...previousFacts, `covered ${messages.length} messages`],
  summary: `Summary of ${messages.length} messages.`,
});

describe('budgetFor', () => {
  it.each([4096, 8192, 16384, 32768])('is consistent for %i', nCtx => {
    const budget = budgetFor(nCtx);
    expect(budget.promptLimit + budget.replyReserve).toBeLessThan(nCtx);
    expect(budget.targetTokens).toBeLessThan(budget.triggerTokens);
    expect(budget.softTriggerTokens).toBeLessThan(budget.triggerTokens);
    expect(budget.softTriggerTokens).toBeLessThanOrEqual(nCtx * 0.7);
    expect(budget.replyReserve).toBeGreaterThanOrEqual(1024);
    expect(budget.summaryTokens).toBeLessThanOrEqual(nCtx * 0.12 + 1);
  });

  it('survives odd sizes', () => {
    expect(budgetFor(2048).promptLimit).toBeGreaterThan(1000);
    expect(budgetFor(0).nCtx).toBe(1024);
    expect(budgetFor(200000).replyReserve).toBe(4096);
  });
});

describe('fitContext', () => {
  const budget = budgetFor(4096);

  it('returns a short chat untouched', async () => {
    const messages = [system, ...chat(3), {role: 'user', content: 'Next?'}];
    const fit = await fitContext({messages, budget, counter});
    expect(fit.messages).toEqual(messages);
    expect(fit).toMatchObject({
      compacted: false,
      summarized: false,
      shrunkNewest: false,
      offerNewChat: false,
    });
    expect(fit.state.cutCount).toBe(0);
  });

  it('cuts to the target in one step and summarises what it removed', async () => {
    const history = [...chat(40), {role: 'user', content: 'Newest question?'}];
    const fit = await fitContext({
      messages: [system, ...history],
      budget,
      counter,
      summarize,
    });
    expect(fit.compacted).toBe(true);
    expect(fit.summarized).toBe(true);
    expect(fit.promptTokens).toBeLessThanOrEqual(budget.targetTokens);
    expect(fit.promptTokens).toBeGreaterThan(budget.targetTokens * 0.6);
    expect(fit.state.cutCount).toBeGreaterThan(0);
    expect(fit.state.summarizedCount).toBe(fit.state.cutCount);
    expect(fit.state.compactions).toBe(1);
    // System text first, summary at its end, then history from a user turn.
    expect(
      messageText(fit.messages[0]).text.startsWith('You are AntiChat.'),
    ).toBe(true);
    expect(fit.messages[0].content).toContain(SUMMARY_BLOCK_HEADER);
    expect(fit.messages[0].content).toContain(
      `covered ${fit.state.cutCount} messages`,
    );
    expect(fit.messages[1].role).toBe('user');
    expect(fit.messages[fit.messages.length - 1]).toEqual({
      role: 'user',
      content: 'Newest question?',
    });
    expect(fit.messages.filter(m => m.role === 'system')).toHaveLength(1);
  });

  it('then leaves the prefix alone until the trigger is passed again', async () => {
    let history = [...chat(40), {role: 'user', content: 'Q?'}];
    let fit = await fitContext({
      messages: [system, ...history],
      budget,
      counter,
      summarize,
    });
    const first = fit;
    const prefixes: string[] = [];
    let recompacted = 0;
    for (let i = 0; i < 12; i++) {
      history = [
        ...history,
        {role: 'assistant', content: `More ${filler(i, 60)}`},
        {role: 'user', content: `Follow-up ${i}?`},
      ];
      fit = await fitContext({
        messages: [system, ...history],
        budget,
        counter,
        summarize,
        state: fit.state,
      });
      expect(fit.promptTokens).toBeLessThanOrEqual(budget.promptLimit);
      if (fit.compacted) {
        recompacted++;
      } else {
        prefixes.push(JSON.stringify(fit.messages.slice(0, 3)));
      }
    }
    expect(recompacted).toBeLessThanOrEqual(2);
    expect(prefixes[0]).toBe(JSON.stringify(first.messages.slice(0, 3)));
  });

  it('never separates a tool call from its results', async () => {
    const history: ChatMessage[] = [];
    for (let i = 0; i < 30; i++) {
      history.push({role: 'user', content: `Search ${i}: ${filler(i, 20)}`});
      history.push({
        role: 'assistant',
        content: '',
        tool_calls: [
          {
            id: `c${i}`,
            type: 'function',
            function: {name: 'web_search', arguments: '{}'},
          },
        ],
      });
      history.push({
        role: 'tool',
        tool_call_id: `c${i}`,
        content: filler(i + 9, 80),
      });
      history.push({role: 'assistant', content: `Found ${filler(i + 77, 40)}`});
    }
    history.push({role: 'user', content: 'And now?'});
    const fit = await fitContext({
      messages: [system, ...history],
      budget,
      counter,
      summarize,
    });
    expect(fit.compacted).toBe(true);
    expect(fit.messages[1].role).toBe('user');
    const ids = new Set<string>();
    for (const message of fit.messages) {
      (message.tool_calls as Array<{id: string}> | undefined)?.forEach(call =>
        ids.add(call.id),
      );
      if (message.role === 'tool') {
        expect(ids.has(message.tool_call_id as string)).toBe(true);
      }
    }
  });

  it('slides the window when no summariser is available, and catches up later', async () => {
    let history = [...chat(40), {role: 'user', content: 'Q?'}];
    const slid = await fitContext({
      messages: [system, ...history],
      budget,
      counter,
    });
    expect(slid.compacted).toBe(true);
    expect(slid.summarized).toBe(false);
    expect(slid.state.summarizedCount).toBe(0);
    expect(slid.messages[0]).toEqual(system);

    const failing: Summarizer = async () => null;
    const failed = await fitContext({
      messages: [system, ...history],
      budget,
      counter,
      summarize: failing,
    });
    expect(failed.summarized).toBe(false);
    expect(failed.promptTokens).toBeLessThanOrEqual(budget.promptLimit);

    history = [...history, ...chat(25), {role: 'user', content: 'Later?'}];
    const seen: number[] = [];
    const later = await fitContext({
      messages: [system, ...history],
      budget,
      counter,
      state: slid.state,
      summarize: async request => {
        seen.push(request.messages.length);
        return summarize(request);
      },
    });
    // The messages dropped without a summary are summarised now.
    expect(seen[0]).toBe(later.state.cutCount);
    expect(later.state.summarizedCount).toBe(later.state.cutCount);
  });

  it('shortens the newest message only when it alone does not fit', async () => {
    const huge = `Please review this: ${filler(1, 6000)} THE END`;
    const fit = await fitContext({
      messages: [system, ...chat(3), {role: 'user', content: huge}],
      budget,
      counter,
      summarize,
    });
    expect(fit.shrunkNewest).toBe(true);
    expect(fit.promptTokens).toBeLessThanOrEqual(budget.promptLimit);
    const newest = messageText(fit.messages[fit.messages.length - 1]).text;
    expect(newest).toContain(MIDDLE_MARKER.trim());
    expect(newest.startsWith('Please review this:')).toBe(true);
    expect(newest.endsWith('THE END')).toBe(true);
    expect(fit.messages).toHaveLength(2);
  });

  it('fits even when the system prompt and tools eat most of the window', async () => {
    const bigSystem = {role: 'system', content: filler(3, 1800)};
    const tools = Array.from({length: 6}, (_, i) => ({
      type: 'function',
      function: {name: `tool_${i}`, description: filler(i, 40), parameters: {}},
    })) as never;
    const fit = await fitContext({
      messages: [
        bigSystem,
        ...chat(20),
        {role: 'user', content: filler(9, 300)},
      ],
      tools,
      budget,
      counter,
      summarize,
    });
    expect(fit.promptTokens).toBeLessThanOrEqual(budget.promptLimit);
    expect(fit.messages[fit.messages.length - 1].role).toBe('user');
  });

  it('drops a summary that no longer describes the history (edit, regenerate)', async () => {
    const history = [...chat(40), {role: 'user', content: 'Q?'}];
    const first = await fitContext({
      messages: [system, ...history],
      budget,
      counter,
      summarize,
    });
    const edited = [
      {role: 'user', content: 'A different first question'},
      ...history.slice(1),
    ];
    const again = await fitContext({
      messages: [system, ...edited],
      budget,
      counter,
      summarize,
      state: first.state,
    });
    expect(again.state.compactions).toBe(1);
    expect(again.state.facts).toEqual([
      `covered ${again.state.cutCount} messages`,
    ]);

    const shorter = await fitContext({
      messages: [system, {role: 'user', content: 'Fresh start'}],
      budget,
      counter,
      state: first.state,
    });
    expect(shorter.state.cutCount).toBe(0);
    expect(shorter.messages[0]).toEqual(system);
  });

  it('keeps a carried summary across a reset and shows it to the model', async () => {
    const state: ContextState = {
      ...emptyContextState(),
      carried: {
        facts: ['The dog is called Biscuit'],
        summary: 'They planned a trip.',
      },
    };
    const fit = await fitContext({
      messages: [system, {role: 'user', content: 'Where were we?'}],
      budget,
      counter,
      state,
    });
    expect(fit.messages[0].content).toBe(
      'You are AntiChat.\n\n# Summary of the previous chat\nThe user continued from an earlier chat. This is what it established; treat it as known.\nFacts:\n- The dog is called Biscuit\nSummary: They planned a trip.',
    );
    expect(renderSummaryBlock(emptyContextState())).toBe('');
  });

  it('offers a new chat after repeated compactions', async () => {
    let history: ChatMessage[] = [];
    let state: ContextState | null = null;
    let offered = false;
    for (let round = 0; round < 12 && !offered; round++) {
      history = [
        ...history,
        ...chat(25),
        {role: 'user', content: `Round ${round}?`},
      ];
      const fit = await fitContext({
        messages: [system, ...history],
        budget,
        counter,
        summarize,
        state,
      });
      state = fit.state;
      offered = fit.offerNewChat;
      history.push({role: 'assistant', content: 'ok'});
    }
    expect(offered).toBe(true);
    expect(state!.compactions).toBeGreaterThanOrEqual(OFFER_NEW_CHAT_AFTER);
  });

  it('compacts early at a soft trigger', async () => {
    const soft = budget.softTriggerTokens;
    let history = chat(1);
    while ((await counter.countPrompt([system, ...history])) < soft + 50) {
      history = [...history, ...chat(1)];
    }
    const untouched = await fitContext({
      messages: [system, ...history],
      budget,
      counter,
      summarize,
    });
    expect(untouched.compacted).toBe(false);
    const early = await fitContext({
      messages: [system, ...history],
      budget,
      counter,
      summarize,
      trigger: soft,
    });
    expect(early.compacted).toBe(true);
  });

  it('works without a system message', async () => {
    const fit = await fitContext({
      messages: [...chat(40), {role: 'user', content: 'Q?'}],
      budget,
      counter,
      summarize,
    });
    expect(fit.messages[0].role).toBe('system');
    expect(fit.messages[0].content).toContain(SUMMARY_BLOCK_HEADER);
  });

  it('fingerprints content, not identity', () => {
    const a = chat(3);
    expect(fingerprint(a)).toBe(fingerprint(JSON.parse(JSON.stringify(a))));
    expect(fingerprint(a)).not.toBe(fingerprint(chat(4)));
  });
});

describe('truncation rules', () => {
  it('cuts a tool result at the head and marks it', async () => {
    const text = filler(1, 2000);
    const cut = await truncateHead(text, 300, counter);
    expect(await counter.countText(cut)).toBeLessThanOrEqual(300);
    expect(cut.endsWith(HEAD_MARKER)).toBe(true);
    expect(text.startsWith(cut.slice(0, 200))).toBe(true);
    expect(await truncateHead('short', 300, counter)).toBe('short');
  });

  it('keeps the start and the end of a long paste', async () => {
    const text = `START ${filler(2, 3000)} END`;
    const cut = await truncateMiddle(text, 500, counter);
    expect(await counter.countText(cut)).toBeLessThanOrEqual(500);
    expect(cut.startsWith('START')).toBe(true);
    expect(cut.endsWith('END')).toBe(true);
    expect(cut).toContain(MIDDLE_MARKER);
  });

  it('applies the insertion limits by role, deterministically', async () => {
    const limits = {toolResultTokens: 100, attachmentTokens: 200};
    const messages: ChatMessage[] = [
      {role: 'system', content: filler(1, 900)},
      {role: 'user', content: filler(2, 900)},
      {role: 'assistant', content: filler(3, 900)},
      {role: 'tool', tool_call_id: 'c', content: filler(4, 900)},
      {
        role: 'user',
        content: [
          {type: 'text', text: filler(5, 900)},
          {type: 'image_url', image_url: {url: 'file://a.jpg'}},
        ],
      },
      {role: 'user', content: 'short'},
    ];
    const once = await applyInsertionLimits(messages, limits, counter);
    expect(once[0]).toBe(messages[0]);
    expect(once[2]).toBe(messages[2]);
    expect(once[5]).toBe(messages[5]);
    expect(
      await counter.countText(once[1].content as string),
    ).toBeLessThanOrEqual(200);
    expect(
      await counter.countText(once[3].content as string),
    ).toBeLessThanOrEqual(100);
    const parts = once[4].content as Array<{type: string; text?: string}>;
    expect(parts[1].type).toBe('image_url');
    expect(await counter.countText(parts[0].text!)).toBeLessThanOrEqual(200);
    const twice = await applyInsertionLimits(once, limits, counter);
    expect(twice).toEqual(once);
  });
});
