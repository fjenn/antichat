// Relay policy (architecture §8.1/§8.3, M7.T10 step 5): configuration from env, toolkit policy (every Composio
// toolkit unless RELAY_ALLOWED_TOOLKITS narrows it), minimum client version, kill switch. Production refuses to
// start when it is misconfigured.
import { logConfigError } from "./log.js";

export const RELAY_VERSION = "1.0.0";
/** Stub value of COMPOSIO_API_KEY in dev: every Composio route answers 503 relay.notConfigured. */
export const STUB_KEY = "dev-not-a-key";
/**
 * The eight apps of the first releases. No longer a limit: `toolkits` of GET /v1/connections still carries them when
 * every toolkit is allowed, because app versions up to 0.0.7 show exactly that list.
 */
export const DEFAULT_TOOLKITS = [
  "gmail", "googlecalendar", "googledrive", "slack", "notion", "github", "linear", "outlook",
];

export type Limits = {
  mcpPerMin: number;
  executionsPerDay: number;
  sessionsPerHour: number;
  linksPerHour: number;
  catalogPerHour: number;
  newIdsPerIpPerHour: number;
  globalDailyCap: number;
};

export type RelayConfig = {
  production: boolean;
  /** undefined when unset or the stub: the relay is "not configured" and never calls Composio. */
  composioKey: string | undefined;
  composioBaseUrl: string | undefined;
  hmacSecret: string;
  upstash: { url: string; token: string } | undefined;
  /** "*" = every toolkit Composio offers (the default); a list = only those (RELAY_ALLOWED_TOOLKITS). */
  allowedToolkits: string[] | "*";
  minClientVersion: string;
  disabled: boolean;
  limits: Limits;
};

export class ConfigError extends Error {
  constructor(readonly reason: string) {
    super(reason);
  }
}

type Env = Record<string, string | undefined>;

function intVar(env: Env, name: string, dflt: number): number {
  const raw = env[name];
  if (raw === undefined || raw === "") return dflt;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 0) throw new ConfigError(`${name} must be a non-negative integer`);
  return n;
}

/** Reads and validates the env. Throws ConfigError (names of variables only, never values). */
export function loadConfig(env: Env = process.env): RelayConfig {
  const production = env.VERCEL_ENV === "production";
  const rawKey = env.COMPOSIO_API_KEY?.trim();
  const composioKey = rawKey && rawKey !== STUB_KEY ? rawKey : undefined;
  const composioBaseUrl = env.COMPOSIO_BASE_URL?.trim() || undefined;

  const hmacSecret = env.INSTALL_ID_HMAC_SECRET ?? "";
  if (hmacSecret.length < 32) throw new ConfigError("INSTALL_ID_HMAC_SECRET must be set (>= 32 chars)");

  const upUrl = env.UPSTASH_REDIS_REST_URL?.trim();
  const upToken = env.UPSTASH_REDIS_REST_TOKEN?.trim();
  const upstash = upUrl && upToken ? { url: upUrl, token: upToken } : undefined;

  if (production) {
    if (composioBaseUrl) throw new ConfigError("COMPOSIO_BASE_URL is dev/test only and must not be set in production");
    if (env.COMPOSIO_ALLOW_INSECURE_HTTP) throw new ConfigError("COMPOSIO_ALLOW_INSECURE_HTTP must not be set in production");
    // Release 2 (owner decision): Upstash is optional. Without it the store, every per-install limit and
    // RELAY_GLOBAL_DAILY_CAP are kept per instance (in memory); buildContext logs relay.limitsPerInstance.
  }

  const tk = env.RELAY_ALLOWED_TOOLKITS?.trim();
  const allowedToolkits: string[] | "*" =
    !tk || tk === "*" ? "*" : tk.split(",").map((s) => s.trim().toLowerCase()).filter(Boolean);

  let mcpPerMin = 60;
  if (env.RELAY_TEST_MCP_PER_MIN !== undefined && env.RELAY_TEST_MCP_PER_MIN !== "") {
    if (production) {
      logConfigError("relay.testOverrideIgnored");
    } else {
      mcpPerMin = intVar(env, "RELAY_TEST_MCP_PER_MIN", 60);
    }
  }

  return {
    production,
    composioKey,
    composioBaseUrl,
    hmacSecret,
    upstash,
    allowedToolkits,
    minClientVersion: env.RELAY_MIN_CLIENT_VERSION?.trim() || "0",
    disabled: env.RELAY_DISABLED === "1",
    limits: {
      mcpPerMin,
      executionsPerDay: 500,
      sessionsPerHour: 10,
      linksPerHour: 10,
      catalogPerHour: 30,
      newIdsPerIpPerHour: 20,
      globalDailyCap: intVar(env, "RELAY_GLOBAL_DAILY_CAP", 10000),
    },
  };
}

/** A Composio toolkit slug as the relay passes it on: lowercase letters, digits, `_`, `-`. */
export function toolkitSlugOk(toolkit: string): boolean {
  return /^[a-z0-9_-]{1,64}$/.test(toolkit);
}

export function toolkitAllowed(cfg: RelayConfig, toolkit: string): boolean {
  if (!toolkitSlugOk(toolkit)) return false;
  return cfg.allowedToolkits === "*" || cfg.allowedToolkits.includes(toolkit);
}

/** Leading dotted number of a version string ("0.7.1 (412)" → [0,7,1]); [] when none. */
function parts(v: string): number[] {
  const m = /^\s*v?(\d+(?:\.\d+)*)/.exec(v);
  return m?.[1] ? m[1].split(".").map(Number) : [];
}

/** True when `client` is below `min`. A missing/garbled client version counts as outdated unless min is "0". */
export function belowMinVersion(client: string | null, min: string): boolean {
  const want = parts(min);
  if (want.every((n) => n === 0)) return false;
  const have = client ? parts(client) : [];
  if (have.length === 0) return true;
  for (let i = 0; i < Math.max(want.length, have.length); i++) {
    const a = have[i] ?? 0;
    const b = want[i] ?? 0;
    if (a !== b) return a < b;
  }
  return false;
}
