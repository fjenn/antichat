// AT-255 c6 + M7.T10 step 6/7: logs carry only {route,status,latency_ms,uid8}; the store holds only sess:* and
// limiter keys after a full mocked session, and none of the fixture's JSON-RPC payload text.
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import { RELAY_DIR } from "../scripts/local-server.js";
import { INSTALL_A, INSTALL_B, runFullSession, startHarness, type Harness } from "./harness.js";

function files(dir: string): string[] {
  return readdirSync(dir).flatMap((n) => {
    const p = join(dir, n);
    return statSync(p).isDirectory() ? files(p) : p.endsWith(".ts") ? [p] : [];
  });
}

describe("console lint", () => {
  const src = [...files(join(RELAY_DIR, "api")), ...files(join(RELAY_DIR, "src"))];

  it("only src/log.ts calls console.* in the deployed code", () => {
    const offenders = src.filter((f) => !f.endsWith("src/log.ts") && /\bconsole\s*\./.test(readFileSync(f, "utf8")));
    expect(offenders.map((f) => relative(RELAY_DIR, f))).toEqual([]);
  });

  it("log.ts passes nothing but JSON.stringify(line) of the fixed entry to console", () => {
    const text = readFileSync(join(RELAY_DIR, "src/log.ts"), "utf8");
    const calls = [...text.matchAll(/console\.(\w+)\(([^;]*)\);/g)].map((m) => m[2]);
    expect(calls).toEqual(["JSON.stringify(line)", "JSON.stringify(line)", "JSON.stringify(line)"]);
  });

  it("no console.* call anywhere (incl. scripts) receives a body, args, params or result", () => {
    const all = [...src, ...files(join(RELAY_DIR, "scripts"))];
    const bad: string[] = [];
    for (const f of all) {
      for (const m of readFileSync(f, "utf8").matchAll(/console\.\w+\(([^;]*)\)/g)) {
        if (/\b(req|request)\.(body|json|text)|\bbody\b|\bargs\b|\barguments\b|\bparams\b|\bresult\b/.test(m[1] ?? "")) {
          bad.push(`${relative(RELAY_DIR, f)}: ${m[0]}`);
        }
      }
    }
    expect(bad).toEqual([]);
  });
});

describe("full mocked session", () => {
  let h: Harness;
  const lines: string[] = [];
  beforeAll(async () => {
    const capture = (...a: unknown[]) => void lines.push(a.map(String).join(" "));
    vi.spyOn(console, "log").mockImplementation(capture);
    vi.spyOn(console, "error").mockImplementation(capture);
    vi.spyOn(console, "warn").mockImplementation(capture);
    vi.spyOn(console, "info").mockImplementation(capture);
    h = await startHarness();
    await runFullSession(h, INSTALL_A);
    await runFullSession(h, INSTALL_B);
  });
  afterAll(async () => {
    await h.close();
    vi.restoreAllMocks();
  });

  it("every log line is exactly {route,status,latency_ms,uid8}", () => {
    expect(lines.length).toBeGreaterThan(20);
    for (const l of lines) {
      const o = JSON.parse(l) as Record<string, unknown>;
      expect(Object.keys(o).sort()).toEqual(["latency_ms", "route", "status", "uid8"]);
      expect(typeof o.uid8 === "string" ? o.uid8 : "").toMatch(/^([0-9a-f]{8})?$/);
    }
  });

  it("logs and store contain no fixture payload text, install IDs or the key", async () => {
    const phrases = h.mock.fixturePhrases();
    expect(phrases).toContain("Quarterly garden plan draft");
    const dump = JSON.stringify(await h.ctx.kv.dump());
    const logs = lines.join("\n");
    for (const p of [...phrases, "Moss sample results", "The moss sample from the north wall came back healthy.", INSTALL_A, INSTALL_B, "test-mock-key"]) {
      expect(dump.includes(p), `store contains ${p}`).toBe(false);
      expect(logs.includes(p), `logs contain ${p}`).toBe(false);
    }
  });

  it("the only keys are sess:<userId> and limiter counters", async () => {
    const keys = Object.keys(await h.ctx.kv.dump());
    expect(keys.length).toBeGreaterThan(0);
    for (const k of keys) expect(k).toMatch(/^(sess:ac_[0-9a-f]{32}|rl:(mcp|exec|session|link|newid|global):[^:]+:\d+)$/);
    const sess = Object.entries(await h.ctx.kv.dump()).filter(([k]) => k.startsWith("sess:"));
    for (const [, v] of sess) expect(Object.keys(JSON.parse(v)).sort()).toEqual(["sid", "url"]);
  });
});
