// Key dump for AT-255 c6 (R-255 AC6). With UPSTASH_REDIS_REST_URL/TOKEN set: SCANs the Upstash store and prints
// key names with their Redis type (values are not printed). Without Upstash: runs a full mocked session (two
// installs, fixture readonly + send, every connections route) against test/mock-composio.ts in process and prints
// the in-memory store (keys and values), then checks that only sess:* and limiter keys exist and that no fixture
// phrase appears. Exit 1 on a violation. Usage: npx tsx scripts/dump-keys.ts [--json <out>]
import { writeFileSync } from "node:fs";
import { Redis } from "@upstash/redis";
import { UpstashKV } from "../src/store.js";

const KEY_RULE = /^(cat:toolkits|sess:ac_[0-9a-f]{32}|rl:(mcp|exec|session|link|catalog|newid|global):[^:]+:\d+)$/;

async function main() {
  const outIdx = process.argv.indexOf("--json");
  const out = outIdx > 0 ? process.argv[outIdx + 1] : undefined;
  let dump: Record<string, string>;
  let phrases: string[] = [];
  let mode: string;
  let statuses: Record<string, number> = {};
  if (process.env.UPSTASH_REDIS_REST_URL && process.env.UPSTASH_REDIS_REST_TOKEN) {
    mode = "upstash";
    dump = await new UpstashKV(new Redis({ url: process.env.UPSTASH_REDIS_REST_URL, token: process.env.UPSTASH_REDIS_REST_TOKEN })).dump();
  } else {
    mode = "memory (full mocked session)";
    const { startHarness, runFullSession, INSTALL_A, INSTALL_B } = await import("../test/harness.js");
    const log = console.log;
    console.log = () => {}; // request log lines are not part of the dump
    const h = await startHarness();
    try {
      statuses = await runFullSession(h, INSTALL_A);
      await runFullSession(h, INSTALL_B);
      dump = await h.ctx.kv.dump();
      phrases = [...h.mock.fixturePhrases(), INSTALL_A, INSTALL_B, "test-mock-key"];
    } finally {
      await h.close();
      console.log = log;
    }
  }
  const badKeys = Object.keys(dump).filter((k) => !KEY_RULE.test(k));
  const text = JSON.stringify(dump);
  const leaked = phrases.filter((p) => text.includes(p));
  const report = {
    mode,
    session_statuses: statuses,
    key_count: Object.keys(dump).length,
    keys: dump,
    phrases_checked: phrases.length,
    bad_keys: badKeys,
    leaked_phrases: leaked,
    pass: badKeys.length === 0 && leaked.length === 0,
  };
  const json = JSON.stringify(report, null, 2);
  if (out) writeFileSync(out, json + "\n");
  process.stdout.write(json + "\n");
  process.exit(report.pass ? 0 : 1);
}

void main();
