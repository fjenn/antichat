// AT-255 c2 (relay half): same install ID → same ac_… userId on repeat calls; a new ID → a new userId.
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { deriveUserId, installIdFrom, isInstallId, networkKey } from "../src/identity.js";
import { INSTALL_A, INSTALL_B, startHarness, type Harness } from "./harness.js";

const SECRET = "x".repeat(40);

describe("identity derivation", () => {
  it("is ac_ + 32 hex of HMAC-SHA256(secret, installId), deterministic", () => {
    const a = deriveUserId(SECRET, INSTALL_A);
    expect(a).toMatch(/^ac_[0-9a-f]{32}$/);
    expect(deriveUserId(SECRET, INSTALL_A)).toBe(a);
    expect(deriveUserId(SECRET, INSTALL_A.toUpperCase())).toBe(a);
    expect(deriveUserId(SECRET, INSTALL_B)).not.toBe(a);
    expect(deriveUserId("y".repeat(40), INSTALL_A)).not.toBe(a);
  });

  it("accepts only UUIDv4 install IDs", () => {
    expect(isInstallId(INSTALL_A)).toBe(true);
    expect(isInstallId("3f2b8c1e-4d5a-1b6c-8d7e-9f0a1b2c3d4e")).toBe(false); // v1
    expect(isInstallId("not-a-uuid")).toBe(false);
    expect(isInstallId(undefined)).toBe(false);
    expect(installIdFrom(new Headers({ "X-AntiChat-Install": ` ${INSTALL_A} ` }))).toBe(INSTALL_A);
    expect(installIdFrom(new Headers())).toBeNull();
  });

  it("groups IPv6 clients by /64 and never exposes the raw address", () => {
    const k = (ip: string) => networkKey(SECRET, new Headers({ "x-forwarded-for": ip }));
    expect(k("2001:db8:1:2::5")).toBe(k("2001:0db8:0001:0002:ffff::9"));
    expect(k("2001:db8:1:2::5")).not.toBe(k("2001:db8:1:3::5"));
    expect(k("198.51.100.7")).not.toBe(k("198.51.100.8"));
    expect(k("198.51.100.7")).toMatch(/^[0-9a-f]{16}$/);
  });
});

describe("relay identity over HTTP (mock Composio)", () => {
  let h: Harness;
  beforeAll(async () => {
    h = await startHarness();
  });
  afterAll(async () => h.close());

  it("same install twice → one Composio user; new install → new user", async () => {
    for (const id of [INSTALL_A, INSTALL_A, INSTALL_B]) {
      const r = await h.call("/v1/session", { method: "POST", install: id });
      expect(r.status).toBe(200);
      expect(await r.json()).toEqual({ ok: true });
    }
    const users = [...h.mock.sessions.values()].map((s) => s.userId);
    expect(users).toHaveLength(2); // second call for A reused the cached session
    const secret = h.ctx.cfg.hmacSecret;
    expect(users).toEqual([deriveUserId(secret, INSTALL_A), deriveUserId(secret, INSTALL_B)]);
    expect(users[0]).not.toBe(users[1]);
  });

  it("missing or malformed install header → 400 relay.badRequest, no Composio call", async () => {
    const before = h.mock.log.length;
    for (const install of [null, "1234"]) {
      const r = await h.call("/v1/session", { method: "POST", install });
      expect(r.status).toBe(400);
      expect(await r.json()).toEqual({ code: "relay.badRequest" });
    }
    expect(h.mock.log.length).toBe(before);
  });
});
