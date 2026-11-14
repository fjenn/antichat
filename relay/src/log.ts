// Structured logs (architecture §8.1, M7.T10 step 6). One JSON line per request with exactly
// {route, status, latency_ms, uid8}. NEVER bodies, headers, tool arguments or results: the entry type
// below is the only thing that reaches the console, and test/noContentLogs.test.ts lints that no other
// file calls console.* and that nothing else is passed in.
import { createHash } from "node:crypto";

export type LogEntry = {
  route: string;
  status: number;
  latency_ms: number;
  uid8: string | null;
};

/** Static configuration problems (no user data). Logged with the same four fields plus this code. */
export type ConfigCode =
  | "relay.testOverrideIgnored"
  | "relay.misconfigured"
  | "relay.limitsPerInstance";

/** 8 hex chars of sha256(userId): enough to correlate one install's lines, not to recover the id. */
export function uid8(userId: string | null | undefined): string | null {
  if (!userId) return null;
  return createHash("sha256").update(userId).digest("hex").slice(0, 8);
}

export function logRequest(entry: LogEntry): void {
  const line: LogEntry = {
    route: entry.route,
    status: entry.status,
    latency_ms: Math.max(0, Math.round(entry.latency_ms)),
    uid8: entry.uid8,
  };
  console.log(JSON.stringify(line));
}

/** A static configuration notice (status 200): e.g. production without Upstash keeps its limits per instance. */
export function logConfigNotice(code: ConfigCode): void {
  const line: LogEntry & { code: ConfigCode } = { route: "config", status: 200, latency_ms: 0, uid8: null, code };
  console.log(JSON.stringify(line));
}

export function logConfigError(code: ConfigCode): void {
  const line: LogEntry & { code: ConfigCode } = { route: "config", status: 500, latency_ms: 0, uid8: null, code };
  console.error(JSON.stringify(line));
}
