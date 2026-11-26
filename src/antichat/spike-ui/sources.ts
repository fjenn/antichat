/**
 * Token sources for the spike: a scripted one at a fixed rate and the real
 * model through llama.rn. Both call `onToken` once per token on the JS thread,
 * which is what the chat engine will do.
 */
import {Platform} from 'react-native';
import * as RNFS from '@dr.pogodin/react-native-fs';
import {initLlama, type LlamaContext} from 'llama.rn';

import {SCRIPTED_ANSWER, tokenize} from './script';

export type SourceKind = 'script15' | 'script30' | 'script60' | 'model';

export type TokenRun = {
  /** Resolves when the stream is over (finished or stopped). */
  done: Promise<{tokens: number; seconds: number; stopped: boolean}>;
  stop: () => void;
};

export const SOURCE_LABEL: Record<SourceKind, string> = {
  script15: '15/s',
  script30: '30/s',
  script60: '60/s',
  model: 'Model',
};

export function scriptedRun(
  tokensPerSecond: number,
  onToken: (token: string) => void,
  text: string = SCRIPTED_ANSWER,
): TokenRun {
  const tokens = tokenize(text);
  let stopped = false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let finish: (r: {tokens: number; seconds: number; stopped: boolean}) => void;
  const done = new Promise<{
    tokens: number;
    seconds: number;
    stopped: boolean;
  }>(resolve => {
    finish = resolve;
  });
  const t0 = Date.now();
  let sent = 0;
  // Clock-driven, so a late timer emits the tokens it missed in a burst, the
  // way a model does after the JS thread was busy.
  const tick = () => {
    if (stopped) {
      return;
    }
    const due = Math.min(
      tokens.length,
      Math.floor(((Date.now() - t0) / 1000) * tokensPerSecond) + 1,
    );
    while (sent < due) {
      onToken(tokens[sent++]);
    }
    if (sent >= tokens.length) {
      finish({tokens: sent, seconds: (Date.now() - t0) / 1000, stopped: false});
      return;
    }
    timer = setTimeout(tick, 1000 / tokensPerSecond);
  };
  timer = setTimeout(tick, 250); // time to first token
  return {
    done,
    stop: () => {
      stopped = true;
      clearTimeout(timer);
      finish({tokens: sent, seconds: (Date.now() - t0) / 1000, stopped: true});
    },
  };
}

/** Where a GGUF for the spike is looked for (copied in by hand, never downloaded). */
export const modelDirs = (): string[] =>
  [
    `${RNFS.DocumentDirectoryPath}/spike-models`,
    Platform.OS === 'android' && RNFS.ExternalDirectoryPath
      ? `${RNFS.ExternalDirectoryPath}/spike-models`
      : '',
  ].filter(Boolean);

export async function findModel(): Promise<string | null> {
  for (const dir of modelDirs()) {
    if (!(await RNFS.exists(dir))) {
      continue;
    }
    const files = (await RNFS.readDir(dir))
      .filter(f => f.name.endsWith('.gguf') && !f.name.includes('mmproj'))
      .sort((a, b) => Number(a.size) - Number(b.size));
    if (files.length > 0) {
      return files[0].path;
    }
  }
  return null;
}

let context: LlamaContext | undefined;
let contextPath: string | undefined;

export async function loadModel(): Promise<{path: string; loadMs: number}> {
  const path = await findModel();
  if (!path) {
    throw new Error(`No .gguf in ${modelDirs().join(' or ')}`);
  }
  const t0 = Date.now();
  if (!context || contextPath !== path) {
    context = await initLlama({
      model: path,
      n_ctx: 4096,
      n_batch: 512,
      n_gpu_layers: 99,
      use_mmap: true,
      use_mlock: false,
      ctx_shift: false,
    });
    contextPath = path;
  }
  return {path, loadMs: Date.now() - t0};
}

export function modelRun(
  prompt: string,
  onToken: (token: string) => void,
): TokenRun {
  const t0 = Date.now();
  let tokens = 0;
  let stopped = false;
  const done = (async () => {
    await loadModel();
    await context!.completion(
      {
        messages: [
          {
            role: 'system',
            content:
              'You are a helpful assistant. Answer in Markdown and use headings, lists, a table, a code block and LaTeX where they fit.',
          },
          {role: 'user', content: prompt},
        ],
        jinja: true,
        enable_thinking: false,
        reasoning_format: 'auto',
        n_predict: 900,
        temperature: 0.7,
        seed: 42,
      },
      data => {
        if (data.token) {
          tokens += 1;
          onToken(data.token);
        }
      },
    );
    return {tokens, seconds: (Date.now() - t0) / 1000, stopped};
  })();
  return {
    done,
    stop: () => {
      stopped = true;
      context?.stopCompletion().catch(() => {});
    },
  };
}

export function startRun(
  kind: SourceKind,
  prompt: string,
  onToken: (token: string) => void,
  text?: string,
): TokenRun {
  switch (kind) {
    case 'script15':
      return scriptedRun(15, onToken, text);
    case 'script30':
      return scriptedRun(30, onToken, text);
    case 'script60':
      return scriptedRun(60, onToken, text);
    case 'model':
      return modelRun(prompt, onToken);
  }
}
