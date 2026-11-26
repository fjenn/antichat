/**
 * Chat ports for the device harness: a scripted model with fixed timing, and
 * a real one on llama.rn. Both support speculative replies.
 */
import {initLlama, type LlamaContext} from 'llama.rn';

import voiceSkill from '../../../skills/data/voice-mode.json';
import type {
  SpeculativeReply,
  VoiceChatPort,
  VoiceReplyCallbacks,
  VoiceReplyResult,
  VoiceSendOptions,
} from '../../mode/chatPort';

const sleep = (ms: number) =>
  new Promise<void>(resolve => setTimeout(resolve, ms));

interface Run {
  attach(callbacks: VoiceReplyCallbacks): void;
  done: Promise<VoiceReplyResult['status']>;
  stop(): void;
}

/** Wraps "start generating for this text" into the port, with speculation. */
function portFrom(
  thread: {role: 'user' | 'assistant'; content: string}[],
  generate: (text: string) => Run,
): VoiceChatPort {
  let current: Run | null = null;
  const commit = async (
    text: string,
    run: Run,
    callbacks: VoiceReplyCallbacks,
  ): Promise<VoiceReplyResult> => {
    current = run;
    let answer = '';
    run.attach({
      onDelta: delta => {
        answer += delta;
        callbacks.onDelta(delta);
      },
    });
    const status = await run.done;
    thread.push(
      {role: 'user', content: text},
      {role: 'assistant', content: answer},
    );
    return {status, conversationId: 'harness'};
  };
  return {
    send: (text, _options: VoiceSendOptions, callbacks) =>
      commit(text, generate(text), callbacks),
    stop: () => current?.stop(),
    speculate(text): SpeculativeReply {
      const run = generate(text);
      return {
        text,
        commit: callbacks => commit(text, run, callbacks),
        cancel: () => run.stop(),
      };
    },
  };
}

/** Buffers deltas until someone listens. */
function buffered(): {
  emit(delta: string): void;
  attach(callbacks: VoiceReplyCallbacks): void;
} {
  const seen: string[] = [];
  let listener: VoiceReplyCallbacks | null = null;
  return {
    emit(delta) {
      seen.push(delta);
      listener?.onDelta(delta);
    },
    attach(callbacks) {
      seen.forEach(delta => callbacks.onDelta(delta));
      listener = callbacks;
    },
  };
}

/** A model with a fixed time to first token and token rate. */
export function createScriptedChat(
  reply: string,
  timing = {firstTokenMs: 400, tokensPerSecond: 20},
): VoiceChatPort & {thread: {role: string; content: string}[]} {
  const thread: {role: 'user' | 'assistant'; content: string}[] = [];
  const port = portFrom(thread, () => {
    const out = buffered();
    let stopped = false;
    const done = (async () => {
      await sleep(timing.firstTokenMs);
      for (const word of reply.split(/(?<=\s)/)) {
        if (stopped) {
          return 'stopped' as const;
        }
        out.emit(word);
        await sleep(1000 / timing.tokensPerSecond);
      }
      return 'complete' as const;
    })();
    return {attach: out.attach, done, stop: () => (stopped = true)};
  });
  return Object.assign(port, {thread});
}

/** A real model on llama.rn, prompted with the voice-mode skill. */
export async function createLlamaChat(
  modelPath: string,
): Promise<VoiceChatPort & {release(): Promise<void>; loadMs: number}> {
  const started = Date.now();
  const context: LlamaContext = await initLlama({
    model: modelPath,
    n_ctx: 2048,
    n_batch: 512,
    n_gpu_layers: 99,
    use_mmap: true,
    use_mlock: false,
  });
  const loadMs = Date.now() - started;
  const thread: {role: 'user' | 'assistant'; content: string}[] = [];
  // One completion at a time: a cancelled speculation must be out of the
  // context before the real request starts.
  let busy: Promise<unknown> = Promise.resolve();
  const port = portFrom(thread, text => {
    const out = buffered();
    let stopped = false;
    let running = false;
    const done = (busy = busy
      .catch(() => {})
      .then(async () => {
        if (stopped) {
          return 'stopped' as const;
        }
        running = true;
        await context.completion(
          {
            jinja: true,
            enable_thinking: false,
            reasoning_format: 'auto',
            temperature: 0.4,
            n_predict: 96,
            // No history: every turn costs the same, so runs can be compared.
            messages: [
              {
                role: 'system',
                content: `You are a helpful assistant. ${voiceSkill.body}`,
              },
              {role: 'user', content: text},
            ],
          },
          data => {
            if (data.token && !stopped) {
              out.emit(data.token);
            }
          },
        );
        running = false;
        return stopped ? ('stopped' as const) : ('complete' as const);
      })) as Promise<'complete' | 'stopped'>;
    return {
      attach: out.attach,
      done,
      stop: () => {
        stopped = true;
        if (running) {
          Promise.resolve(context.stopCompletion()).catch(() => {});
        }
      },
    };
  });
  return Object.assign(port, {
    loadMs,
    release: async () => {
      await busy.catch(() => {});
      await context.release();
    },
  });
}
