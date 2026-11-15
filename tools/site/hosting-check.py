#!/usr/bin/env python3
"""AT-304 hosting check (M10.T05 step 4, R-304 AC2/AC3; D-007/D-010). `python3 -I`; stdlib only.

Fetches the site over HTTP and checks what the host serves, not just what the build wrote:
  feeds    appcast.xml enclosures → https://github.com/<githubRepo>/releases/download/…; appcast-dev.xml may also
           use $DEV_BASE_URL (default http://192.168.64.1:8765, the local feed host of M10.md "Hosting and accounts");
  catalog  catalog/v2/catalog.json (+ its <catalog_version>.json): every models.*.files[].sources[] URL is
           https://huggingface.co/<owner>/<repo>/resolve/<40-hex commit>/… (pinned, no mirror; D-010) or, per A-M5-11,
           https://raw.githubusercontent.com/<owner>/<repo>/<40-hex commit>/… (vid-taehv), and every
           runtimes[].url is a GitHub release download or the site itself (dev hosts only with --dev);
  headers  every checked path: Content-Security-Policy equal to the built vercel.json and without any third-party
           origin, X-Content-Type-Options nosniff, Referrer-Policy, Permissions-Policy, no Set-Cookie (AC3);
  types    HTML text/html, feeds XML, catalog/CIMD JSON, security.txt text/plain (RFC 9116), .sig not HTML;
  routing  an unknown path is a real 404 (no SPA fallback for feed/catalog clients); a page without its trailing
           slash resolves on the same host;
  https    (URL mode only) the base is https, http:// redirects (301/308) to https:// on the same host, HSTS is sent,
           and every redirect stays on https.

Modes:
  local (default)  serves --dist (default site/dist, from `make site`) with tools/site/serve-site.py on 127.0.0.1
                   (vercel.json headers applied) and checks it; HTTPS legs print `pending (deployed host)`.
  --url <base>     checks a deployed host (preview or production). Owner-only until the site is deployed
                   (docs/prd/M10-owner-steps.md §4); it only reads (GET/HEAD), never publishes.
  --dev            accept the dev hosts (DEV_BASE_URL, http://localhost:4321 of `make site-dev`) in appcast-dev.xml
                   and catalog runtimes[].url; without it a dev host in the served catalog is a release blocker.
Exit 0 = no failure (pending legs are listed, not failed); 1 = failures; 2 = usage.
Usage: hosting-check.py [--dist site/dist | --url https://host] [--dev] [--json out.json]"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
# D-010 / A-M5-11: Hugging Face commit URLs, or a GitHub raw URL pinned by commit (vid-taehv; catalog-v2 schema).
PINNED = re.compile(r"^https://(huggingface\.co/[^/\s]+/[^/\s]+/resolve|raw\.githubusercontent\.com/[^/\s]+/[^/\s]+)"
                    r"/[0-9a-f]{40}/\S+$")
DEFAULT_DEV_BASE = "http://192.168.64.1:8765"
SITE_DEV = "http://localhost:4321"
PAGES = ["/", "/download/", "/help/faq/", "/legal/privacy/", "/legal/terms/"]
REQUIRED_HEADERS = {"x-content-type-options": "nosniff", "referrer-policy": None, "permissions-policy": None}
CSP_REQUIRED = ["default-src 'self'", "frame-ancestors 'none'", "connect-src 'self'"]


@dataclass
class Report:
    passed: list[str] = field(default_factory=list)
    failed: list[str] = field(default_factory=list)
    pending: list[str] = field(default_factory=list)

    def check(self, ok: bool, what: str) -> bool:
        (self.passed if ok else self.failed).append(what)
        return ok


@dataclass
class Resp:
    status: int
    headers: dict[str, list[str]]
    body: bytes
    location: str | None = None

    def h(self, name: str) -> str | None:
        v = self.headers.get(name.lower())
        return v[0] if v else None


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):  # noqa: ANN002, ANN003
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def fetch(url: str, method: str = "GET") -> Resp:
    """One request, redirects not followed (the caller checks each hop)."""
    req = urllib.request.Request(url, method=method, headers={"User-Agent": "antichat-hosting-check"})
    try:
        r = _OPENER.open(req, timeout=20)
        status, hdrs, body = r.status, r.headers, r.read()
    except urllib.error.HTTPError as e:
        status, hdrs, body = e.code, e.headers, e.read()
    except (urllib.error.URLError, OSError) as e:  # unreachable host, TLS failure: status 0, reason in the body
        return Resp(0, {}, str(e).encode())
    headers: dict[str, list[str]] = {}
    for k, v in hdrs.items():
        headers.setdefault(k.lower(), []).append(v)
    return Resp(status, headers, body, (headers.get("location") or [None])[0])


def follow(url: str, max_hops: int = 5) -> tuple[Resp, list[str]]:
    """GET with redirects followed by hand, never off the starting host; returns the last response and every URL
    seen (an off-host target is listed but not fetched, so the caller's same-host check fails on it)."""
    hops = [url]
    host = urllib.parse.urlparse(url).netloc
    r = fetch(url)
    while r.status in (301, 302, 303, 307, 308) and r.location and len(hops) <= max_hops:
        url = urllib.parse.urljoin(url, r.location)
        hops.append(url)
        if urllib.parse.urlparse(url).netloc != host:
            break
        r = fetch(url)
    return r, hops


# ---- content checks (pure; unit-tested) ----

def enclosure_urls(xml_text: str) -> list[str]:
    root = ET.fromstring(xml_text.split("<!-- sparkle-signatures:", 1)[0].strip())
    return [e.get("url", "") for e in root.iter("enclosure")]


def release_prefix(repo: str) -> str:
    return f"https://github.com/{repo}/releases/download/"


def check_appcast(xml_text: str, repo: str, dev_bases: list[str] | None) -> list[str]:
    """Problems with the feed's enclosure hosts; `dev_bases` (appcast-dev.xml) also allows those prefixes."""
    try:
        urls = enclosure_urls(xml_text)
    except ET.ParseError as e:
        return [f"not valid XML ({e})"]
    if not urls:
        return ["no <enclosure> items"]
    allowed = [release_prefix(repo)] + [b.rstrip("/") + "/" for b in dev_bases or []]
    return [f"enclosure {u} is not on {' or '.join(allowed)}" for u in urls if not any(u.startswith(p) for p in allowed)]


def check_catalog(cat: dict, repo: str, site: str, dev_bases: list[str] | None) -> list[str]:
    bad: list[str] = []
    n = 0
    for mid, m in (cat.get("models") or {}).items():
        for f in m.get("files") or []:
            for s in f.get("sources") or []:
                n += 1
                if not PINNED.match(s):
                    bad.append(f"models.{mid}: source {s} is not commit-pinned (huggingface.co/<repo>/resolve/<40-hex>/… "
                               "or raw.githubusercontent.com/<repo>/<40-hex>/…)")
    if n == 0:
        bad.append("catalog lists no model sources")
    allowed = [release_prefix(repo), site.rstrip("/") + "/"] + [b.rstrip("/") + "/" for b in dev_bases or []]
    for rt in cat.get("runtimes") or []:
        u = rt.get("url", "")
        if not any(u.startswith(p) for p in allowed):
            bad.append(f"runtimes.{rt.get('name', '?')}: {u} is not a GitHub release download or the site"
                       + ("" if dev_bases else " (a dev host here is a release blocker; --dev accepts it)"))
    return bad


def csp_problems(csp: str | None, expected: str | None) -> list[str]:
    if not csp:
        return ["no Content-Security-Policy header"]
    bad = [f"CSP lacks {d}" for d in CSP_REQUIRED if d not in csp]
    third = [t for t in csp.replace(";", " ").split() if re.match(r"^(https?:|wss?:|\*)", t)]
    if third:
        bad.append(f"CSP allows other origins: {' '.join(third)}")
    if expected is not None and csp != expected:
        bad.append("CSP differs from the built vercel.json (stale deploy or headers not applied)")
    return bad


def header_problems(r: Resp, expected_csp: str | None) -> list[str]:
    bad = csp_problems(r.h("content-security-policy"), expected_csp)
    for k, v in REQUIRED_HEADERS.items():
        got = r.h(k)
        if got is None or (v is not None and got.strip().lower() != v):
            bad.append(f"{k}: {got!r}" + (f" (want {v})" if v else " (missing)"))
    if "set-cookie" in r.headers:
        bad.append("sets a cookie")
    return bad


def type_ok(path: str, ctype: str | None) -> bool:
    c = (ctype or "").split(";")[0].strip().lower()
    if path.endswith("/") or path.endswith(".html"):
        return c == "text/html"
    if path.endswith(".xml"):
        return c in ("application/xml", "text/xml", "application/rss+xml")
    if path.endswith(".json"):
        return c == "application/json"
    if path.endswith(".txt"):
        return c == "text/plain"
    if path.endswith(".sig"):
        return bool(c) and c != "text/html"
    return bool(c)


# ---- the run ----

def expected_headers_csp(dist: Path | None) -> str | None:
    cfg = (dist / "vercel.json") if dist else ROOT / "site/vercel.json"
    if not cfg.exists():
        return None
    for h in json.loads(cfg.read_text()).get("headers", []):
        for x in h["headers"]:
            if x["key"].lower() == "content-security-policy":
                return x["value"]
    return None


def run(base: str, *, remote: bool, dist: Path | None, dev: bool, rep: Report) -> None:
    hosting = json.loads((ROOT / "Config/Hosting.json").read_text())
    repo, site = hosting["githubRepo"], hosting["siteURL"]
    dev_bases = [os.environ.get("DEV_BASE_URL", DEFAULT_DEV_BASE), SITE_DEV] if dev else None
    base = base.rstrip("/")
    csp = expected_headers_csp(dist)
    if dist is not None:
        rep.check((dist / "vercel.json").exists(), "dist/vercel.json present (the headers config that deploys)")
        if dist == (ROOT / "site/dist").resolve() and (dist / "vercel.json").exists():
            rep.check((dist / "vercel.json").read_text() == (ROOT / "site/vercel.json").read_text(),
                      "dist/vercel.json equals site/vercel.json")

    # HTTPS and redirects (deployed host only).
    if remote:
        u = urllib.parse.urlparse(base)
        rep.check(u.scheme == "https", f"base URL is https ({base})")
        r = fetch("http://" + u.netloc + "/")
        loc = urllib.parse.urlparse(urllib.parse.urljoin("http://" + u.netloc + "/", r.location or ""))
        rep.check(r.status in (301, 308) and loc.scheme == "https" and loc.netloc == u.netloc,
                  f"http:// redirects to https:// on the same host (got {r.status} → {r.location})")
        r = fetch(base + "/")
        hsts = r.h("strict-transport-security") or ""
        rep.check("max-age=" in hsts, f"Strict-Transport-Security sent ({hsts or 'missing'})")
    else:
        rep.pending.append("HTTPS, http→https redirect and HSTS: pending (deployed host; "
                           "python3 -I tools/site/hosting-check.py --url https://<preview or site host>)")

    # Pages, headers and content types.
    paths = list(PAGES) + ["/appcast-dev.xml", "/catalog/v2/catalog.json", "/catalog/v2/catalog.json.sig",
                           "/.well-known/security.txt", "/oauth/mcp-client-metadata.json"]
    appcast = fetch(base + "/appcast.xml")
    if appcast.status == 200:
        paths.append("/appcast.xml")
    elif remote and not dev:
        rep.check(False, f"/appcast.xml served (got {appcast.status})")
    else:
        rep.pending.append("appcast.xml (production feed): pending (written by the release, M10.T10; "
                           "this build has only appcast-dev.xml)")
    bodies: dict[str, bytes] = {}
    for p in paths:
        r, hops = follow(base + p)
        if not rep.check(r.status == 200, f"GET {p} → 200 (got {r.status})"):
            continue
        bodies[p] = r.body
        if len(hops) > 1:
            rep.check(all(urllib.parse.urlparse(h).netloc == urllib.parse.urlparse(base).netloc for h in hops)
                      and (not remote or all(h.startswith("https://") for h in hops[1:])),
                      f"{p}: redirects stay on the host{' and https' if remote else ''} ({' → '.join(hops)})")
        probs = header_problems(r, csp)
        rep.check(not probs, f"{p}: security headers" + (f" — {'; '.join(probs)}" if probs else ""))
        rep.check(type_ok(p, r.h("content-type")), f"{p}: Content-Type {r.h('content-type')}")

    # Routing.
    r = fetch(base + "/no-such-page-hosting-check/")
    rep.check(r.status == 404, f"unknown path → 404 (got {r.status})")
    r, hops = follow(base + "/legal/terms")
    rep.check(r.status == 200 and all(urllib.parse.urlparse(h).netloc == urllib.parse.urlparse(base).netloc for h in hops),
              f"/legal/terms (no trailing slash) resolves on the host ({' → '.join(hops)} → {r.status})")

    # Feeds and catalog content.
    if "/appcast.xml" in bodies:
        probs = check_appcast(bodies["/appcast.xml"].decode(errors="replace"), repo, None)
        rep.check(not probs, "appcast.xml enclosures on GitHub Releases" + (f" — {'; '.join(probs)}" if probs else ""))
    if "/appcast-dev.xml" in bodies:
        probs = check_appcast(bodies["/appcast-dev.xml"].decode(errors="replace"), repo,
                              [os.environ.get("DEV_BASE_URL", DEFAULT_DEV_BASE)])
        rep.check(not probs, "appcast-dev.xml enclosures on GitHub Releases or $DEV_BASE_URL"
                  + (f" — {'; '.join(probs)}" if probs else ""))
    cat = None
    if "/catalog/v2/catalog.json" in bodies:
        try:
            cat = json.loads(bodies["/catalog/v2/catalog.json"])
        except ValueError as e:
            rep.check(False, f"catalog.json is valid JSON ({e})")
    if isinstance(cat, dict):
        probs = check_catalog(cat, repo, site, dev_bases)
        rep.check(not probs, "catalog.json model sources commit-pinned (HF / GitHub raw), runtimes on allowed hosts"
                  + (f" — {'; '.join(probs[:8])}{' …' if len(probs) > 8 else ''}" if probs else ""))
        v = cat.get("catalog_version")
        rv, _ = follow(f"{base}/catalog/v2/{v}.json")
        rep.check(rv.status == 200 and rv.body == bodies["/catalog/v2/catalog.json"],
                  f"catalog/v2/{v}.json served and equal to catalog.json")


def load_server():
    spec = importlib.util.spec_from_file_location("serve_site", Path(__file__).with_name("serve-site.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--dist", default=None, help="built site to serve locally (default site/dist)")
    g.add_argument("--url", default=None, help="deployed base URL (preview or production)")
    ap.add_argument("--dev", action="store_true", help="accept dev hosts in appcast-dev.xml and catalog runtimes")
    ap.add_argument("--json", default=None)
    a = ap.parse_args(argv)
    rep = Report()
    if a.url:
        run(a.url, remote=True, dist=None, dev=a.dev, rep=rep)
        mode = f"url {a.url}"
    else:
        dist = Path(a.dist or ROOT / "site/dist").resolve()
        if not (dist / "index.html").exists():
            print(f"hosting-check: {dist} has no index.html (run make site)", file=sys.stderr)
            return 2
        srv, base = load_server().serve(dist)
        try:
            run(base, remote=False, dist=dist, dev=a.dev, rep=rep)
        finally:
            srv.shutdown()
        mode = f"local {dist} via {base}"
    for x in rep.passed:
        print(f"ok       {x}")
    for x in rep.pending:
        print(f"PENDING  {x}")
    for x in rep.failed:
        print(f"FAIL     {x}")
    print(f"hosting-check ({mode}{', --dev' if a.dev else ''}): {len(rep.passed)} ok, {len(rep.failed)} failed, "
          f"{len(rep.pending)} pending")
    if a.json:
        Path(a.json).parent.mkdir(parents=True, exist_ok=True)
        Path(a.json).write_text(json.dumps({"mode": mode, "dev": a.dev, "passed": rep.passed, "failed": rep.failed,
                                            "pending": rep.pending}, indent=2) + "\n")
    return 1 if rep.failed else 0


if __name__ == "__main__":
    sys.exit(main())
