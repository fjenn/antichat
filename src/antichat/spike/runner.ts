/**
 * Unattended on-device spike (docs/research/03-spike-protocol.md, steps 1-3).
 * For every *.gguf in Documents/spike-models, smallest first, it measures
 * load time, memory, time to first token, tokens per second cold and after a
 * sustained run, then the 30 tool cases in two modes and the chat sanity set,
 * and writes Documents/spike-results/<model>.json after every stage.
 *
 * A model that throws on load is recorded and skipped. A model that kills the
 * process (jetsam, native abort) is detected on the next launch through
 * status.json, recorded as crashed and skipped, so relaunching resumes.
 */
import {initLlama, releaseAllLlama, BuildInfo} from 'llama.rn';
import type {LlamaContext} from 'llama.rn';

import {C1_PROMPT, C8_PROMPT, CHAT_CASES} from './chatSet';
import {getLaunchConfig, spikeNative} from './native';
import type {MemoryReading, ModelFile} from './native';
import {runToolCases, stripThinkBlock, toolTestAssets} from './toolcalls';

export const MODELS_DIR = 'spike-models';
export const RESULTS_DIR = 'spike-results';
const STATUS_FILE = `${RESULTS_DIR}/status.json`;
const LOG_FILE = `${RESULTS_DIR}/spike.log`;

type Status = {
  started: string;
  finished: boolean;
  finished_at?: string;
  heartbeat?: string;
  models: Record<
    string,
    {state: 'running' | 'done' | 'load_failed' | 'crashed'; stage?: string}
  >;
};

type Options = {
  sustainSec: number;
  nCtx: number;
  nGpuLayers: number;
  idleSec: number;
  cooldownSec: number;
  toolLimit: number;
  chatLimit: number;
  skip: Set<string>;
  models: string[];
  force: boolean;
  reset: boolean;
};

const sleep = (ms: number) => new Promise<void>(r => setTimeout(r, ms));
const round = (n: number, d = 2) => Math.round(n * 10 ** d) / 10 ** d;
const mean = (a: number[]) =>
  a.length ? a.reduce((x, y) => x + y, 0) / a.length : 0;

function readOptions(): Options {
  const o = getLaunchConfig().options;
  const num = (key: string, fallback: number) => {
    const v = Number(o[`antichatSpike${key}`]);
    return Number.isFinite(v) && o[`antichatSpike${key}`] !== undefined
      ? v
      : fallback;
  };
  const list = (key: string) =>
    (o[`antichatSpike${key}`] ?? '')
      .split(',')
      .map(s => s.trim())
      .filter(Boolean);
  return {
    sustainSec: num('SustainSec', 600),
    nCtx: num('NCtx', 8192),
    nGpuLayers: num('NGpuLayers', 99),
    idleSec: num('IdleSec', 10),
    cooldownSec: num('CooldownSec', 300),
    toolLimit: num('ToolLimit', 0),
    chatLimit: num('ChatLimit', 0),
    skip: new Set(list('Skip')),
    models: list('Models'),
    force: o.antichatSpikeForce === '1',
    reset: o.antichatSpikeReset === '1',
  };
}

export async function runSpike(log: (line: string) => void): Promise<void> {
  const native = spikeNative;
  if (!native) {
    log('AntiChatSpike native module missing (iOS debug builds only)');
    return;
  }
  const say = (line: string) => {
    const stamped = `${new Date().toISOString()} ${line}`;
    native.appendLine(LOG_FILE, stamped);
    console.log(`[spike] ${line}`);
    log(line);
  };
  const cfg = getLaunchConfig();
  const opts = readOptions();
  native.setKeepAwake(true);

  let status: Status = {
    started: new Date().toISOString(),
    finished: false,
    models: {},
  };
  if (!opts.reset) {
    try {
      const raw = await native.readFile(STATUS_FILE);
      if (raw) {
        status = {...JSON.parse(raw), finished: false};
      }
    } catch {}
  }
  const saveStatus = () => {
    status.heartbeat = new Date().toISOString();
    return native.writeFile(STATUS_FILE, JSON.stringify(status, null, 1));
  };

  const launchMemory = await native.getMemory();
  const all = await native.listModels(MODELS_DIR);
  const models = all.filter(
    m =>
      !/mmproj/i.test(m.name) &&
      (opts.models.length === 0 || opts.models.some(f => m.name.includes(f))),
  );
  say(
    `spike start: ${cfg.device.machine} iOS ${cfg.device.os_version} (${cfg.device.os_build}), ` +
      `RAM ${round(cfg.device.physical_memory / 2 ** 30)} GiB, available ${round(launchMemory.available / 2 ** 20, 0)} MiB, ` +
      `${models.length} model(s): ${models.map(m => m.name).join(', ') || 'none'}`,
  );
  await native.writeFile(
    `${RESULTS_DIR}/_run.json`,
    JSON.stringify(
      {
        schema: 1,
        started: new Date().toISOString(),
        device: cfg.device,
        launch_memory: launchMemory,
        options: cfg.options,
        llama_rn: BuildInfo,
        models_found: all,
      },
      null,
      1,
    ),
  );
  await saveStatus();

  let ran = 0;
  for (const model of models) {
    const prev = status.models[model.name];
    const resultFile = `${RESULTS_DIR}/${model.name.replace(/\.gguf$/i, '')}.json`;
    if (prev?.state === 'running') {
      // The previous launch died inside this model.
      say(
        `${model.name}: process died during "${prev.stage}" on the previous launch; skipping`,
      );
      status.models[model.name] = {state: 'crashed', stage: prev.stage};
      let partial: any = {};
      try {
        partial = JSON.parse((await native.readFile(resultFile)) ?? '{}');
      } catch {}
      await native.writeFile(
        resultFile,
        JSON.stringify(
          {
            ...partial,
            schema: 1,
            model,
            device: cfg.device,
            status: 'crashed',
            crashed_stage: prev.stage,
          },
          null,
          1,
        ),
      );
      await saveStatus();
      continue;
    }
    if (prev && !opts.force) {
      say(`${model.name}: already ${prev.state}; skipping`);
      continue;
    }
    if (ran > 0 && opts.cooldownSec > 0) {
      await coolDown(opts.cooldownSec, say);
    }
    ran++;
    const state = await runModel(model, resultFile, opts, say, async stage => {
      status.models[model.name] = {state: 'running', stage};
      await saveStatus();
    });
    status.models[model.name] = {state};
    await saveStatus();
  }

  status.finished = true;
  status.finished_at = new Date().toISOString();
  await saveStatus();
  native.setKeepAwake(false);
  say('spike finished');
}

async function coolDown(maxSec: number, say: (l: string) => void) {
  const t0 = Date.now();
  while ((Date.now() - t0) / 1000 < maxSec) {
    const m = await spikeNative!.getMemory();
    if (m.thermal_level === 0 && Date.now() - t0 > 5000) {
      break;
    }
    await sleep(5000);
  }
  say(`cool-down ${round((Date.now() - t0) / 1000, 0)} s`);
}

async function runModel(
  model: ModelFile,
  resultFile: string,
  opts: Options,
  say: (l: string) => void,
  setStage: (stage: string) => Promise<void>,
): Promise<'done' | 'load_failed'> {
  const native = spikeNative!;
  const cfg = getLaunchConfig();
  const initParams = {
    model: model.path,
    n_ctx: opts.nCtx,
    n_batch: 512,
    n_ubatch: 512,
    n_gpu_layers: opts.nGpuLayers,
    flash_attn_type: 'auto' as const,
    cache_type_k: 'f16' as const,
    cache_type_v: 'f16' as const,
    use_mmap: true,
    use_mlock: false,
    kv_unified: true,
    n_parallel: 1,
    ctx_shift: false,
  };
  const result: any = {
    schema: 1,
    model: {file: model.name, size_bytes: model.size},
    device: cfg.device,
    settings: {...initParams, model: undefined, sustain_sec: opts.sustainSec},
    started: new Date().toISOString(),
    status: 'running',
    errors: {},
    memory: {},
    load: {},
  };
  const save = () =>
    native.writeFile(resultFile, JSON.stringify(result, null, 1));
  const mem = (): Promise<MemoryReading> => native.getMemory();
  let ctx: LlamaContext | undefined;

  /** Runs one stage; a thrown error is recorded and the run continues. */
  const stage = async (name: string, fn: () => Promise<void>) => {
    if (opts.skip.has(name)) {
      return;
    }
    await setStage(name);
    say(`${model.name}: ${name}`);
    const t0 = Date.now();
    try {
      await fn();
    } catch (e: any) {
      result.errors[name] = String(e?.message ?? e).slice(0, 1000);
      say(`${model.name}: ${name} FAILED: ${result.errors[name]}`);
    }
    result.stage_seconds = {
      ...result.stage_seconds,
      [name]: round((Date.now() - t0) / 1000, 1),
    };
    await save();
  };

  const complete = async (params: any) => {
    const t0 = Date.now();
    let ttft: number | null = null;
    const out = await ctx!.completion(
      {
        jinja: true,
        enable_thinking: false,
        reasoning_format: 'auto',
        seed: 42,
        ...params,
      },
      () => {
        ttft ??= Date.now() - t0;
      },
    );
    return {out, ttft_ms: ttft, wall_ms: Date.now() - t0};
  };
  const user = (content: string) => [{role: 'user', content}];

  native.startSampling(2000);
  await setStage('load');
  say(`${model.name}: load (${round(model.size / 2 ** 30)} GiB)`);
  await sleep(opts.idleSec * 1000);
  result.memory.before_load = await mem();

  // ---- load, cold
  try {
    const t0 = Date.now();
    ctx = await initLlama(initParams);
    result.load.cold_ms = Date.now() - t0;
  } catch (e: any) {
    result.status = 'load_failed';
    result.error = String(e?.message ?? e).slice(0, 2000);
    result.memory.after_failed_load = await mem();
    result.memory.peak = await native.stopSampling();
    result.finished = new Date().toISOString();
    await save();
    say(`${model.name}: LOAD FAILED: ${result.error}`);
    await releaseAllLlama().catch(() => {});
    return 'load_failed';
  }
  result.memory.after_load = await mem();
  result.memory.peak_during_load = await native.readSampling();
  result.load.gpu = ctx.gpu;
  result.load.reason_no_gpu = ctx.reasonNoGPU;
  result.load.devices = ctx.devices;
  result.model.desc = ctx.model?.desc;
  result.model.n_params = ctx.model?.nParams;
  result.model.template_caps = ctx.model?.chatTemplates?.jinja;
  await save();
  say(
    `${model.name}: loaded in ${result.load.cold_ms} ms, gpu=${ctx.gpu}, ` +
      `available ${round(result.memory.before_load.available / 2 ** 20, 0)} -> ${round(result.memory.after_load.available / 2 ** 20, 0)} MiB`,
  );

  // ---- load, warm
  await stage('warm', async () => {
    await ctx!.release();
    ctx = undefined;
    const t0 = Date.now();
    ctx = await initLlama(initParams);
    result.load.warm_ms = Date.now() - t0;
  });
  if (!ctx) {
    result.status = 'load_failed';
    result.error = `warm reload failed: ${result.errors.warm}`;
    result.memory.peak = await native.stopSampling();
    await save();
    return 'load_failed';
  }

  await stage('bench', async () => {
    const b = await ctx!.bench(512, 128, 1, 3);
    result.bench = {
      prompt_tps: round(b.speedPp),
      generation_tps: round(b.speedTg),
      raw: b,
    };
  });

  await stage('ttft', async () => {
    const short = await complete({
      messages: user(
        'Give me one interesting fact about the ocean, in a single short sentence please.',
      ),
      n_predict: 48,
      temperature: 0,
    });
    const toolTurn = (question: string) =>
      complete({
        messages: [
          {role: 'system', content: toolTestAssets.systemPrompt},
          ...user(question),
        ],
        tools: toolTestAssets.tools,
        tool_choice: 'auto',
        n_predict: 48,
        temperature: 0,
      });
    const cold = await toolTurn(
      'Hi! Before we start, tell me in one sentence what you can help me with today.',
    );
    const cached = await toolTurn(
      'Thanks. And in one sentence, what can you not do for me?',
    );
    const t = (r: typeof cold) => ({
      ttft_ms: r.ttft_ms,
      prompt_n: r.out.timings?.prompt_n,
      cache_n: r.out.timings?.cache_n,
      prompt_ms: round(r.out.timings?.prompt_ms ?? 0, 0),
      prompt_tps: round(r.out.timings?.prompt_per_second ?? 0),
    });
    result.ttft = {
      short_prompt: t(short),
      tool_prompt_cold: t(cold),
      tool_prompt_cached: t(cached),
    };
  });

  await stage('tps_start', async () => {
    const r = await complete({
      messages: user(C1_PROMPT),
      n_predict: 300,
      temperature: 0.7,
    });
    result.tps_start = {
      tokens_per_second: round(r.out.timings?.predicted_per_second ?? 0),
      predicted_n: r.out.timings?.predicted_n,
      ttft_ms: r.ttft_ms,
      thermal: (await mem()).thermal,
    };
  });

  await stage('sustained', async () => {
    const t0 = Date.now();
    const samples: Array<{
      t_s: number;
      tps: number;
      n: number;
      thermal: string;
      available_mib: number;
    }> = [];
    let seed = 1;
    while ((Date.now() - t0) / 1000 < opts.sustainSec) {
      const r = await complete({
        messages: user(C8_PROMPT),
        n_predict: 400,
        temperature: 0.8,
        seed: seed++,
      });
      const m = await mem();
      samples.push({
        t_s: round((Date.now() - t0) / 1000, 1),
        tps: round(r.out.timings?.predicted_per_second ?? 0),
        n: r.out.timings?.predicted_n ?? 0,
        thermal: m.thermal,
        available_mib: round(m.available / 2 ** 20, 0),
      });
      result.sustained = {partial: true, samples};
      if (samples.length % 5 === 0) {
        await setStage('sustained');
        await save();
      }
    }
    const total = samples.length ? samples[samples.length - 1].t_s : 0;
    const window = Math.min(60, total / 2);
    const first = samples
      .filter(s => s.t_s <= window || s === samples[0])
      .map(s => s.tps);
    const last = samples
      .filter(s => s.t_s > total - window || s === samples[samples.length - 1])
      .map(s => s.tps);
    result.sustained = {
      duration_s: total,
      iterations: samples.length,
      tokens_generated: samples.reduce((a, s) => a + s.n, 0),
      window_s: round(window, 0),
      first_window_tps: round(mean(first)),
      last_window_tps: round(mean(last)),
      ratio: mean(first) ? round(mean(last) / mean(first), 3) : null,
      thermal_end: samples[samples.length - 1]?.thermal,
      samples,
    };
  });

  result.toolcalls = {};
  for (const mode of ['native', 'router'] as const) {
    await stage(`tools_${mode}`, async () => {
      let n = 0;
      result.toolcalls[mode] = await runToolCases(ctx!, mode, {
        limit: opts.toolLimit || undefined,
        onProgress: line => {
          say(`${model.name}: ${line}`);
          // Heartbeat so a host script can see progress during the long run.
          if (++n % 5 === 0) {
            setStage(`tools_${mode}`).catch(() => {});
          }
        },
      });
    });
  }

  await stage('chat', async () => {
    const list = opts.chatLimit
      ? CHAT_CASES.slice(0, opts.chatLimit)
      : CHAT_CASES;
    result.chat = [];
    for (const c of list) {
      const messages: any[] = [];
      let last: Awaited<ReturnType<typeof complete>> | undefined;
      for (const turn of c.turns) {
        messages.push({role: 'user', content: turn});
        last = await complete({
          messages: [...messages],
          n_predict: 400,
          temperature: 0.7,
        });
        messages.push({
          role: 'assistant',
          content: stripThinkBlock(last.out.content ?? last.out.text ?? ''),
        });
      }
      result.chat.push({
        id: c.id,
        looks_for: c.looksFor,
        prompt: c.turns.map(t => (t.length > 300 ? `${t.slice(0, 300)}…` : t)),
        answer: stripThinkBlock(last!.out.content ?? last!.out.text ?? ''),
        score: null, // manual 0-2
        tokens: last!.out.timings?.predicted_n,
        tokens_per_second: round(last!.out.timings?.predicted_per_second ?? 0),
        ttft_ms: last!.ttft_ms,
        hit_limit: (last!.out.tokens_predicted ?? 0) >= 400,
      });
    }
  });

  await setStage('release');
  result.memory.before_release = await mem();
  try {
    await ctx.release();
  } catch (e: any) {
    result.errors.release = String(e?.message ?? e);
  }
  await sleep(opts.idleSec * 1000);
  result.memory.after_release = await mem();
  result.memory.peak = await native.stopSampling();
  result.status = 'ok';
  result.finished = new Date().toISOString();
  await save();
  say(
    `${model.name}: done. start ${result.tps_start?.tokens_per_second} t/s, ` +
      `sustained ${result.sustained?.last_window_tps} t/s, ` +
      `peak footprint ${round(result.memory.peak.peak_phys_footprint / 2 ** 20, 0)} MiB, ` +
      `tools native ${result.toolcalls.native?.passed}/${result.toolcalls.native?.total}, ` +
      `router ${result.toolcalls.router?.passed}/${result.toolcalls.router?.total}`,
  );
  return 'done';
}
