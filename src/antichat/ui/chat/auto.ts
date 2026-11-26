/**
 * Unattended run of the scroll rules (audit §3.3), the keyboard cases, the
 * pin landing and a long stream with frame recording, on the real chat
 * screen. Lifted from the M0 spike (`spike-ui/auto.ts`) so the numbers stay
 * comparable: same checks, same thresholds, same JSON.
 *
 * Results: Documents/antichat-m2/<source>.json and the JS log.
 */
import {Platform} from 'react-native';
import * as RNFS from '@dr.pogodin/react-native-fs';
import DeviceInfo from 'react-native-device-info';
import {KeyboardController} from 'react-native-keyboard-controller';

import {getPorts} from '../../adapters';
import {shellSession} from '../../app/session';
import {FakeChat} from '../../contracts/fakes';
import {
  SCRIPTED_ANSWER,
  SHORT_ANSWER,
  USER_QUESTIONS,
} from '../../spike-ui/script';
import {threadDebug, type AutoSource} from './debug';
import type {FrameStats} from './perf';
import {PIN_GAP, type ThreadMetrics} from './thread/ThreadList';

export interface AutoApi {
  setPhase: (phase: string) => void;
  perfStart: () => void;
  perfStop: () => {js: FrameStats; ui: FrameStats};
}

interface Check {
  pass: boolean;
  detail: string;
  data?: unknown;
}

const RATES: Record<AutoSource, number> = {
  script15: 15,
  script30: 30,
  script60: 60,
  model: 0,
};

const sleep = (ms: number) => new Promise<void>(r => setTimeout(r, ms));
const near = (a: number, b: number, tolerance = 3) =>
  Math.abs(a - b) <= tolerance;
const round = (m: ThreadMetrics): ThreadMetrics =>
  Object.fromEntries(
    Object.entries(m).map(([k, v]) => [
      k,
      typeof v === 'number' ? Math.round(v) : v,
    ]),
  ) as unknown as ThreadMetrics;

const EMPTY: ThreadMetrics = {
  offset: 0,
  viewport: 0,
  content: 0,
  blank: 0,
  lastUserTop: null,
  endGap: 0,
};

export async function runAuto(
  source: AutoSource,
  api: AutoApi,
): Promise<Record<string, unknown>> {
  const ports = getPorts();
  const chat = ports.chat;
  const fake = chat instanceof FakeChat ? chat : null;
  const checks: Record<string, Check> = {};
  const m = () => round(threadDebug.current?.metrics() ?? EMPTY);
  const keyboardHeight = () =>
    Math.round(KeyboardController.state()?.height ?? 0);
  const result: Record<string, unknown> = {
    schema: 2,
    screen: 'chat',
    source,
    backend: fake ? 'fake' : 'real',
    platform: Platform.OS,
    os: DeviceInfo.getSystemVersion(),
    model: DeviceInfo.getModel(),
    emulator: DeviceInfo.isEmulatorSync(),
    dev_bundle: __DEV__,
    started: new Date().toISOString(),
    checks,
  };
  const save = async () => {
    const dir = `${RNFS.DocumentDirectoryPath}/antichat-m2`;
    await RNFS.mkdir(dir);
    await RNFS.writeFile(
      `${dir}/${source}.json`,
      JSON.stringify(result, null, 1),
      'utf8',
    );
  };
  const phase = async (name: string) => {
    api.setPhase(name);
    console.log(`[antichat-auto] ${name}`);
    await save();
  };
  const waitIdle = async (id: string, limitMs = 240_000) => {
    const deadline = Date.now() + limitMs;
    await sleep(300);
    while (chat.isGenerating(id) && Date.now() < deadline) {
      await sleep(250);
    }
    if (chat.isGenerating(id)) {
      chat.stop(id);
      await sleep(500);
    }
  };
  /** A chat holding `turns` finished exchanges, opened on screen. */
  const openSeeded = async (turns: number, long = true): Promise<string> => {
    const conversation = await ports.conversations.create();
    for (let i = 0; i < turns; i++) {
      fake!.seed(
        conversation.id,
        `Question ${i + 1}: explain binary search again, please.`,
        long ? SCRIPTED_ANSWER : SHORT_ANSWER,
      );
    }
    shellSession.open(conversation.id);
    return conversation.id;
  };
  const pinTarget = PIN_GAP;

  // ---- Baseline: frame cadence with nothing happening.
  await phase('idle baseline');
  api.perfStart();
  await sleep(2000);
  result.idle_frames = api.perfStop();

  if (!fake) {
    // The real model: one long answer with frame recording, then a second
    // question to see the pin land while the model is busy.
    await phase('model: long answer');
    shellSession.newChat();
    await sleep(600);
    api.perfStart();
    const startedAt = Date.now();
    const first = await chat.send(null, {
      text: 'Explain binary search in about 600 words. Use headings, a numbered list, a table comparing it with linear search, a Python code block, and the formula for the number of steps in LaTeX.',
    });
    shellSession.open(first.conversationId);
    await waitIdle(first.conversationId);
    const perf = api.perfStop();
    const seconds = (Date.now() - startedAt) / 1000;
    const text =
      chat
        .messages(first.conversationId)
        .find(message => message.id === first.assistantMessageId)?.text ?? '';
    const batch = threadDebug.controller?.lastRun;
    result.stream = {
      source,
      seconds,
      characters: text.length,
      // The store coalesces tokens before the adapter sees them, so this is
      // an estimate from the text (about 4 characters per token).
      tokensPerSecond: Math.round((text.length / 4 / seconds) * 10) / 10,
      batcher: batch,
      frames: perf,
    };
    await phase('model: pin landing');
    const send = chat.send(first.conversationId, {
      text: 'Now the same for interpolation search, briefly.',
    });
    const landing: number[][] = [];
    for (let t = 0; t < 1400; t += 100) {
      await sleep(100);
      const now = m();
      landing.push([t + 100, now.offset, now.lastUserTop ?? -1, now.blank]);
    }
    const pinned = m();
    checks.rule1_question_at_top = {
      pass:
        pinned.lastUserTop !== null && near(pinned.lastUserTop, pinTarget, 6),
      detail: `question top ${pinTarget} px under the top bar right after send`,
      data: pinned,
    };
    result.landing = landing;
    await send;
    await waitIdle(first.conversationId);
  } else {
    fake.setRate(RATES[source]);

    // ---- Rule 4: an old chat opens with the end of the last reply at the bottom.
    await phase('rule4 open old chat');
    const id = await openSeeded(12);
    await sleep(2500);
    const opened = m();
    checks.rule4_open_at_end = {
      pass: near(opened.endGap, 0, 4) && opened.blank === 0,
      detail: 'content end sits on the composer, no empty space',
      data: opened,
    };

    // ---- Rule 5a: at the bottom, the keyboard shrinks the conversation.
    await phase('rule5a keyboard at bottom');
    threadDebug.composer?.focus();
    await sleep(1500);
    const kbOpen = m();
    const kb = keyboardHeight();
    checks.rule5a_keyboard_lifts_at_end = {
      pass: kb > 0 && kbOpen.offset - opened.offset > kb * 0.6,
      detail: 'offset grows by about the keyboard height',
      data: {keyboard: kb, moved: kbOpen.offset - opened.offset},
    };
    await KeyboardController.dismiss();
    await sleep(1200);
    const kbClosed = m();
    checks.keyboard_close_restores = {
      pass: near(kbClosed.offset, opened.offset, 4),
      detail: 'closing the keyboard returns to the same offset (no jump)',
      data: {before: opened.offset, after: kbClosed.offset},
    };

    // ---- Rule 1: on send the question moves to the top; the reply is not followed.
    await phase(`rule1 send + stream ${source}`);
    fake.script(SCRIPTED_ANSWER);
    api.perfStart();
    const startedAt = Date.now();
    const sentAt = Date.now();
    await chat.send(id, {text: USER_QUESTIONS[0]});
    const landing: number[][] = [];
    for (let t = 0; t < 1400; t += 100) {
      await sleep(100);
      const now = m();
      landing.push([
        Date.now() - sentAt,
        now.offset,
        now.lastUserTop ?? -1,
        now.blank,
      ]);
    }
    const pinned = m();
    const offsets: number[] = [];
    while (chat.isGenerating(id) && Date.now() - startedAt < 180_000) {
      offsets.push(m().offset);
      await sleep(500);
    }
    const seconds = (Date.now() - startedAt) / 1000;
    const perf = api.perfStop();
    await sleep(600);
    const afterStream = m();
    const batch = threadDebug.controller?.lastRun;
    checks.rule1_question_at_top = {
      pass:
        pinned.lastUserTop !== null && near(pinned.lastUserTop, pinTarget, 6),
      detail: `question top ${pinTarget} px under the top bar right after send`,
      data: pinned,
    };
    checks.rule1_reply_not_followed = {
      pass:
        offsets.length > 2 &&
        Math.max(...offsets) - Math.min(...offsets) <= 3 &&
        afterStream.endGap < -50,
      detail: 'offset constant while the reply streams past the bottom',
      data: {
        samples: offsets.length,
        min: Math.min(...offsets),
        max: Math.max(...offsets),
        afterStream,
      },
    };
    result.stream = {
      source,
      seconds,
      tokens: batch?.tokens,
      tokensPerSecond: batch ? batch.tokens / seconds : 0,
      batcher: batch,
      frames: perf,
    };
    result.landing = landing;

    // ---- Rule 5b: not at the bottom -> the keyboard overlays the conversation.
    await phase('rule5b keyboard overlay');
    threadDebug.composer?.focus();
    await sleep(1500);
    const overlay = m();
    checks.rule5b_keyboard_overlays_when_not_at_end = {
      pass: keyboardHeight() > 0 && near(overlay.offset, afterStream.offset, 3),
      detail: 'offset unchanged when the keyboard opens mid-thread',
      data: {
        before: afterStream.offset,
        after: overlay.offset,
        keyboard: keyboardHeight(),
      },
    };

    // ---- Composer growth with the keyboard open.
    await phase('composer growth');
    threadDebug.composer?.setText(
      'A long question that wraps over several lines so that the composer has to grow while the keyboard is open and the list above it has to make room for it without jumping.',
    );
    await sleep(700);
    const grown = m();
    threadDebug.composer?.setText('');
    await sleep(1500);
    const shrunk = m();
    checks.composer_growth = {
      pass:
        grown.viewport < overlay.viewport - 40 &&
        near(shrunk.viewport, overlay.viewport, 2),
      detail: 'composer grows with four lines and returns to one line',
      data: {
        rest: overlay.viewport,
        grown: grown.viewport,
        back: shrunk.viewport,
      },
    };
    await KeyboardController.dismiss();
    await sleep(1200);

    // ---- Rule 3: empty space under a short reply; gone after scrolling away and back.
    await phase('rule3 short reply blank space');
    threadDebug.current?.scrollToLatest(false);
    await sleep(600);
    fake.script(SHORT_ANSWER);
    fake.setRate(60);
    await chat.send(id, {text: USER_QUESTIONS[1]});
    await waitIdle(id);
    await sleep(1200);
    const shortPinned = m();
    checks.rule3_blank_allowed = {
      pass:
        shortPinned.lastUserTop !== null &&
        near(shortPinned.lastUserTop, pinTarget, 6) &&
        shortPinned.blank > 100 &&
        shortPinned.endGap > 100,
      detail: 'short reply: question at the top with empty space below',
      data: shortPinned,
    };
    threadDebug.composer?.focus();
    await sleep(1500);
    const blankKb = m();
    checks.rule5c_keyboard_overlays_blank_space = {
      pass: keyboardHeight() > 0 && near(blankKb.offset, shortPinned.offset, 3),
      detail: 'keyboard opens over the empty space; the question stays put',
      data: {
        before: shortPinned.offset,
        after: blankKb.offset,
        keyboard: keyboardHeight(),
      },
    };
    await KeyboardController.dismiss();
    await sleep(1200);
    const blankKbClosed = m();
    checks.rule5c_close_keeps_pin = {
      pass:
        near(blankKbClosed.offset, shortPinned.offset, 3) &&
        blankKbClosed.blank > 100,
      detail: 'closing the keyboard keeps the pinned question',
      data: {
        before: shortPinned.offset,
        after: blankKbClosed.offset,
        blank: blankKbClosed.blank,
      },
    };
    await phase('rule3 scroll away and back');
    threadDebug.current?.scrollToOffset(
      Math.max(0, shortPinned.offset - shortPinned.viewport * 2),
      true,
    );
    await sleep(1500);
    const away = m();
    threadDebug.current?.scrollToLatest(true);
    await sleep(1800);
    const back = m();
    checks.rule3_no_blank_after_return = {
      pass: away.blank === 0 && back.blank === 0 && near(back.endGap, 0, 4),
      detail:
        'after scrolling away and back the view ends at the reply, not in empty space',
      data: {away, back},
    };

    // ---- Rule 2: in a short thread the new message just appears under the reply.
    await phase('rule2 short thread');
    const shortId = await openSeeded(0);
    await sleep(800);
    await chat.send(shortId, {text: USER_QUESTIONS[1]});
    await waitIdle(shortId);
    await sleep(800);
    const firstTurn = m();
    fake.script(
      SHORT_ANSWER.replace('France', 'Italy').replace('Paris', 'Rome'),
    );
    await chat.send(shortId, {text: 'And of Italy?'});
    await waitIdle(shortId);
    await sleep(1000);
    const secondTurn = m();
    checks.rule2_short_thread_not_pinned = {
      pass:
        near(secondTurn.offset, 0, 2) &&
        secondTurn.blank === 0 &&
        secondTurn.lastUserTop !== null &&
        secondTurn.lastUserTop > 100,
      detail: 'second question sits under the first reply; nothing scrolls',
      data: {firstTurn, secondTurn},
    };

    // ---- Long thread: 200 messages. Time to rest at the end, then a
    // programmatic scroll up through history, with frame recording.
    await phase('long thread open');
    fake.script(null);
    api.perfStart();
    const openStart = Date.now();
    await openSeeded(100);
    let settledAt = 0;
    let stable = 0;
    let previous = -1;
    while (Date.now() - openStart < 20_000 && stable < 4) {
      await sleep(100);
      const now = m();
      const atEnd = now.content > 1000 && Math.abs(now.endGap) <= 4;
      stable = atEnd && now.content === previous ? stable + 1 : 0;
      previous = now.content;
      if (stable === 1) {
        settledAt = Date.now() - openStart;
      }
    }
    const openPerf = api.perfStop();
    const longOpen = m();
    await phase('long thread scroll');
    api.perfStart();
    for (let i = 1; i <= 8; i++) {
      threadDebug.current?.scrollToOffset(
        Math.max(0, m().offset - longOpen.viewport * 4),
        true,
      );
      await sleep(450);
    }
    const scrollPerf = api.perfStop();
    const afterScroll = m();
    result.long_thread = {
      messages: 200,
      open_settled_ms: stable >= 4 ? settledAt : null,
      open_frames: openPerf,
      scroll_frames: scrollPerf,
      scrolled_px: longOpen.offset - afterScroll.offset,
      opened: longOpen,
    };
    checks.long_thread_opens_at_end = {
      pass: stable >= 4,
      detail: '200-message chat opens resting at its end',
      data: {settled_ms: settledAt, opened: longOpen},
    };
  }

  result.finished = new Date().toISOString();
  result.passed = Object.values(checks).filter(c => c.pass).length;
  result.failed = Object.entries(checks)
    .filter(([, c]) => !c.pass)
    .map(([name]) => name);
  await phase(`done ${result.passed}/${Object.keys(checks).length}`);
  console.log(`[antichat-auto] RESULT ${JSON.stringify(result)}`);
  return result;
}
