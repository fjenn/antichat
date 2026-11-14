// Install identity (architecture §8.1/§8.2, M7.T10 step 1). The app sends a UUIDv4 install ID (Keychain) in
// X-AntiChat-Install; the Composio user id is "ac_" + the first 32 hex chars of HMAC-SHA256(secret, installId).
// The relay never stores the install ID itself; the mapping is implicit in the HMAC.
import { createHmac } from "node:crypto";

const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function isInstallId(v: string | null | undefined): v is string {
  return typeof v === "string" && UUID_V4.test(v);
}

export function deriveUserId(secret: string, installId: string): string {
  const hex = createHmac("sha256", secret).update(installId.toLowerCase()).digest("hex");
  return "ac_" + hex.slice(0, 32);
}

/** The install ID from the request, or null when missing / not a UUIDv4. */
export function installIdFrom(headers: Headers): string | null {
  const v = headers.get("x-antichat-install")?.trim();
  return isInstallId(v) ? v.toLowerCase() : null;
}

/**
 * Client network for the "new install IDs per IP" limiter: IPv4 address, or the /64 prefix for IPv6.
 * Returned HMAC'd (16 hex chars) so no raw IP lands in a limiter key.
 */
export function networkKey(secret: string, headers: Headers): string {
  const fwd = headers.get("x-forwarded-for")?.split(",")[0]?.trim() || headers.get("x-real-ip")?.trim() || "unknown";
  let net = fwd;
  if (fwd.includes(":") && !/^\d+\.\d+\.\d+\.\d+$/.test(fwd)) {
    net = expandV6(fwd).slice(0, 4).join(":") + "::/64";
  }
  return createHmac("sha256", secret).update("net:" + net).digest("hex").slice(0, 16);
}

function expandV6(ip: string): string[] {
  const clean = ip.replace(/^\[|\]$/g, "").split("%")[0] ?? "";
  const [head = "", tail = ""] = clean.split("::");
  const h = head ? head.split(":") : [];
  const t = clean.includes("::") ? (tail ? tail.split(":") : []) : [];
  const fill = Array(Math.max(0, 8 - h.length - t.length)).fill("0");
  return [...h, ...fill, ...t].map((g) => g.toLowerCase().padStart(4, "0"));
}
