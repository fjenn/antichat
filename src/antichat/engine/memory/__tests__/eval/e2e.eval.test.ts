/**
 * The M9 acceptance script on a real model, through the real pipeline:
 * conversation store (M3) + `prepareRequest` with the system-prompt,
 * context, project and memory providers (M7 seam) + upstream's `runAgent`
 * executing the registered memory tools + the after-reply hook and the
 * idle pass.
 *
 *   1. "Remember that I'm vegetarian" → a memory is saved.
 *   2. A new chat asks for a dinner idea → the answer respects it and the
 *      answer's use record names the memory.
 *   3. The memory is deleted → the next answer no longer has it.
 *   4. A temporary chat writes nothing.
 *   5. A chat with facts in passing is read when the user leaves it.
 *
 * Skipped unless ANTICHAT_MEMORY_E2E is set, e.g.
 *   ANTICHAT_MEMORY_E2E="gemma4:18891,lfm3:18892" \
 *   ANTICHAT_MEMORY_E2E_OUT=/tmp/m9-e2e.json yarn jest e2e.eval --coverage=false
 */
import fs from 'fs';

import {
  createServerCounter,
  createServerEngine,
} from '../../../context/__tests__/support/llamaServer';
import {createContextProvider} from '../../../context/provider';
import {
  createMemoryContextStateStore,
  setContextStateStore,
} from '../../../context/summaryStore';
import {withTokenCache} from '../../../context/tokenCounter';
import type {ModelFamily} from '../../../prompt/modelFamily';
import {createSystemPromptProvider} from '../../../prompt/provider';
import {
  clearRequestProviders,
  registerRequestProvider,
} from '../../../prompt/registry';
import type {ChatMessage, DeviceClass} from '../../../prompt/types';
import {createMemoryEngine} from '../../engine';
import type {MemoryRequestMeta} from '../../types';
import {sendTurn} from '../support/chatLoop';
import {createChatHarness} from '../support/memoryHarness';

const targets = (process.env.ANTICHAT_MEMORY_E2E ?? '')
  .split(',')
  .filter(Boolean)
  .map(entry => {
    const [family, port] = entry.split(':');
    return {family: family as ModelFamily, port: Number(port)};
  });

const NOW = new Date(2026, 10, 24, 18, 30);
const MEAT =
  /\b(?:chicken|beef|pork|bacon|salmon|tuna|shrimp|prawns?|lamb|turkey|steak|ham|sausages?|meatballs?|fish|anchov\w+|chorizo|prosciutto)\b/i;

const suite = targets.length
  ? describe.each(targets)
  : describe.skip.each([{family: 'generic' as ModelFamily, port: 0}]);

suite('M9 acceptance on $family', ({family, port}) => {
  // LFM3 is the 4 GB default (4k context); Gemma 4 E2B the 8 GB one (8k).
  const nCtx = family === 'lfm3' ? 4096 : 8192;
  const deviceClass: DeviceClass = family === 'lfm3' ? 'A' : 'C';

  it('remembers, uses, forgets, and keeps temporary chats out', async () => {
    const model = createServerEngine(port);
    const counter = withTokenCache(createServerCounter(port));
    const h = await createChatHarness();
    const current = {id: null as string | null, userText: ''};
    const engine = createMemoryEngine({
      db: h.db,
      chats: h.chats.store,
      now: () => h.clock.now,
      currentSessionId: () => current.id,
      currentUserText: () => current.userText,
      nCtx: () => nCtx,
      acquireModel: () => ({engine: model, family, end: () => {}}),
      deviceClass: () => deviceClass,
      quietMs: 0,
    });
    await engine.init();
    setContextStateStore(createMemoryContextStateStore());
    clearRequestProviders();
    registerRequestProvider(
      createSystemPromptProvider({personalization: () => null}),
    );
    engine.providers.forEach(provider => registerRequestProvider(provider));
    registerRequestProvider(createContextProvider({summarize: false}));

    const log: Record<string, unknown> = {family, nCtx, deviceClass};
    const histories = new Map<string, ChatMessage[]>();

    /** One turn as the app runs it; the chat is mirrored into M3's store. */
    const turn = async (
      sessionId: string,
      userText: string,
      temporary = false,
    ) => {
      current.id = sessionId;
      current.userText = userText;
      const sent = await sendTurn({
        engine: model,
        family,
        nCtx,
        history: histories.get(sessionId) ?? [],
        userText,
        session: {id: sessionId, temporary},
        tools: engine.tools,
        now: NOW,
        counter,
        maxTokens: 300,
      });
      histories.set(sessionId, sent.history);
      h.chats.up.say(sessionId, userText);
      const reply = h.chats.up.answer(sessionId, sent.reply);
      await h.chats.store.syncSession(sessionId);
      const outcome = await engine.afterReply({
        sessionId,
        messageId: reply.id,
        userText,
        reply: sent.reply,
        meta: sent.prepared.meta,
        toolsCalled: sent.toolCalls.map(call => call.name),
      });
      const stats = model.log[model.log.length - 1];
      return {...sent, outcome, messageId: reply.id, stats};
    };
    const memories = async () =>
      (await engine.store.list()).map(memory => memory.text);

    try {
      // 1. Remember.
      const chat1 = h.chats.up.addSession('New chat');
      const remember = await turn(chat1, "Remember that I'm vegetarian");
      const saved = await engine.store.list();
      log.remember = {
        reply: remember.reply,
        toolCalls: remember.toolCalls,
        captured: remember.outcome.captured?.map(r => r.status) ?? null,
        memories: saved.map(memory => [memory.text, memory.origin]),
      };
      expect(saved).toHaveLength(1);
      expect(saved[0].text).toMatch(/vegetarian/i);
      expect(remember.reply.trim().length).toBeGreaterThan(0);

      // 2. A new chat uses it and reports it.
      const chat2 = h.chats.up.addSession('New chat');
      const dinner = await turn(
        chat2,
        'Give me a quick dinner idea for tonight.',
      );
      const meta = dinner.prepared.meta.memory as MemoryRequestMeta;
      const use = await engine.port.useForMessage(dinner.messageId);
      log.dinner = {
        reply: dinner.reply,
        injected: meta.injected,
        memoryTokens: meta.tokens,
        use,
        toolCalls: dinner.toolCalls,
      };
      expect(meta.injected.map(item => item.id)).toEqual([saved[0].id]);
      expect(use?.items.map(item => item.memoryId)).toEqual([saved[0].id]);
      expect(dinner.reply).not.toMatch(MEAT);
      expect(dinner.reply.trim().length).toBeGreaterThan(20);
      // "Reported as used": the reply itself says vegetarian (or names it).
      log.dinnerCited = use?.items[0].cited ?? false;

      // 2b. Second turn of the same chat: the prompt prefix is still cached.
      const followUp = await turn(chat2, 'Something even faster?');
      log.followUp = {
        reply: followUp.reply,
        promptTokens: followUp.stats.promptTokens,
        cachedTokens: followUp.stats.cachedTokens,
        cachedShare: followUp.stats.cachedTokens / followUp.stats.promptTokens,
      };
      expect(followUp.reply).not.toMatch(MEAT);
      // LFM3 is a hybrid model: llama-server reuses next to nothing for it
      // whatever the prompt (m7-prompt-eval.md §6), so only the other
      // families can show that the prefix held.
      if (family !== 'lfm3') {
        expect(
          followUp.stats.cachedTokens / followUp.stats.promptTokens,
        ).toBeGreaterThan(0.6);
      }

      // 3. Delete: it stops.
      await engine.port.delete([saved[0].id]);
      const chat3 = h.chats.up.addSession('New chat');
      const after = await turn(
        chat3,
        'Give me a quick dinner idea for tonight.',
      );
      const afterMeta = after.prepared.meta.memory as MemoryRequestMeta;
      log.afterDelete = {
        reply: after.reply,
        injected: afterMeta.injected,
        mentionsMeat: MEAT.test(after.reply),
        mentionsVegetarian: /vegetarian/i.test(after.reply),
      };
      expect(afterMeta.injected).toEqual([]);
      expect(String(after.prepared.messages[0].content)).not.toMatch(
        /vegetarian/i,
      );
      expect(await engine.port.useForMessage(after.messageId)).toBeNull();
      expect(await engine.port.useForMessage(dinner.messageId)).toBeNull();
      expect(after.reply).not.toMatch(/\bvegetarian\b/i);

      // 4. Temporary chat: nothing is written, whatever the model does.
      const temp = h.chats.up.addSession('Temporary');
      await h.chats.store.markTemporary(temp);
      const before = await h.db.all('SELECT count(*) AS c FROM memory_uses');
      const tempTurn = await turn(
        temp,
        "Remember that I'm allergic to peanuts and my name is Jonas.",
        true,
      );
      h.clock.now += 120_000;
      await engine.leaveChat(temp);
      await engine.idle();
      log.temporary = {
        reply: tempTurn.reply,
        tools: tempTurn.prepared.tools.map(tool => tool.function.name),
        memories: await memories(),
      };
      expect(tempTurn.prepared.tools).toEqual([]);
      expect(await memories()).toEqual([]);
      expect(await h.db.all('SELECT count(*) AS c FROM memory_uses')).toEqual(
        before,
      );
      expect(
        await h.db.all('SELECT * FROM memory_extraction WHERE session_id = ?', [
          temp,
        ]),
      ).toEqual([]);

      // 5. Facts in passing are picked up when the user leaves the chat.
      const chat5 = h.chats.up.addSession('New chat');
      await turn(
        chat5,
        "I'm Maya, I teach chemistry at a high school in Leeds. Suggest a fun demo for my class on Friday.",
      );
      const pass = await engine.leaveChat(chat5);
      log.idlePass = {
        ran: pass.ran,
        chats: pass.chats,
        saved: pass.saved.map(r => [r.status, r.memory?.text]),
        memories: await memories(),
        digest: (await engine.digests.get(chat5))?.digest,
      };
      if (deviceClass !== 'A') {
        expect((await memories()).join(' ')).toMatch(/Maya/);
        expect((await memories()).join(' ')).toMatch(/chemistry|teach/i);
        expect((await memories()).join(' ')).not.toMatch(/friday|demo/i);
      }

      // 6. Reference to a past chat (8k and up): look it up.
      if (nCtx >= 6000) {
        const chat6 = h.chats.up.addSession('New chat');
        const recall = await turn(
          chat6,
          'What was the dinner you suggested to me earlier today? Look it up in our earlier chats.',
        );
        log.recall = {
          reply: recall.reply,
          toolCalls: recall.toolCalls.map(call => ({
            name: call.name,
            args: call.args,
            result: call.result.slice(0, 500),
          })),
        };
      }
    } finally {
      const path = process.env.ANTICHAT_MEMORY_E2E_OUT;
      if (path) {
        fs.writeFileSync(
          path.replace(/\.json$/, `-${family}.json`),
          JSON.stringify(log, null, 1),
        );
      }
      clearRequestProviders();
      h.close();
    }
  }, 900_000);
});
