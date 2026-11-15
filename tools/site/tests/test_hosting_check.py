"""hosting-check.py + serve-site.py self-tests (M10.T05, AT-304). `make test-release-tools`.
Each check must pass on a good site and fail on its seeded violation; the end-to-end legs serve a throwaway dist on
127.0.0.1 (nothing leaves the Mac)."""
from __future__ import annotations

import importlib.util
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

SITE = Path(__file__).resolve().parents[1]
ROOT = SITE.parents[1]


def load(name: str):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), SITE / f"{name}.py")
    m = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = m  # dataclasses resolve their module by name
    spec.loader.exec_module(m)
    return m


hc = load("hosting-check")
srv_mod = load("serve-site")
REPO = json.loads((ROOT / "Config/Hosting.json").read_text())["githubRepo"]
SITE_URL = json.loads((ROOT / "Config/Hosting.json").read_text())["siteURL"]
SHA = "0123456789abcdef0123456789abcdef01234567"
CSP = "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; connect-src 'self'; frame-ancestors 'none'"


def feed(*urls: str) -> str:
    items = "".join(f'<item><enclosure url="{u}" length="1" type="application/octet-stream"/></item>' for u in urls)
    return f'<?xml version="1.0"?><rss version="2.0"><channel>{items}</channel></rss>\n<!-- sparkle-signatures:\nx\n-->'


def catalog(source: str = f"https://huggingface.co/o/r/resolve/{SHA}/m.gguf",
            runtime: str | None = None) -> dict:
    rt = runtime or f"https://github.com/{REPO}/releases/download/v1/rt.zip"
    return {"catalog_version": 3, "models": {"m": {"files": [{"sources": [source]}]}},
            "runtimes": [{"name": "rt", "url": rt}]}


# ---- pure checks ----

def test_appcast_github_release_ok():
    assert hc.check_appcast(feed(f"https://github.com/{REPO}/releases/download/v1/AntiChat.dmg"), REPO, None) == []


def test_appcast_other_host_fails():
    assert hc.check_appcast(feed("https://cdn.example.com/AntiChat.dmg"), REPO, None)


def test_appcast_dev_base_only_for_dev_feed():
    xml = feed("http://192.168.64.1:8765/AntiChat.dmg")
    assert hc.check_appcast(xml, REPO, None)
    assert hc.check_appcast(xml, REPO, ["http://192.168.64.1:8765"]) == []


def test_appcast_empty_or_broken():
    assert hc.check_appcast(feed(), REPO, None) == ["no <enclosure> items"]
    assert "not valid XML" in hc.check_appcast("<rss>", REPO, None)[0]


def test_catalog_pinned_sources():
    assert hc.check_catalog(catalog(), REPO, SITE_URL, None) == []
    raw = f"https://raw.githubusercontent.com/madebyollin/taehv/{SHA}/x.safetensors"
    assert hc.check_catalog(catalog(raw), REPO, SITE_URL, None) == []  # A-M5-11


@pytest.mark.parametrize("bad", ["https://huggingface.co/o/r/resolve/main/m.gguf",
                                 f"https://huggingface.co/o/r/blob/{SHA}/m.gguf",
                                 f"https://mirror.example.com/o/r/resolve/{SHA}/m.gguf",
                                 "https://raw.githubusercontent.com/o/r/main/x.bin"])
def test_catalog_unpinned_or_mirrored_fails(bad):
    assert hc.check_catalog(catalog(bad), REPO, SITE_URL, None)


def test_catalog_runtime_dev_host_needs_dev():
    cat = catalog(runtime="http://localhost:4321/runtimes/rt.zip")
    assert hc.check_catalog(cat, REPO, SITE_URL, None)
    assert hc.check_catalog(cat, REPO, SITE_URL, ["http://localhost:4321"]) == []
    assert hc.check_catalog(catalog(runtime=SITE_URL + "/runtimes/rt.zip"), REPO, SITE_URL, None) == []


def test_catalog_without_sources_fails():
    assert hc.check_catalog({"models": {}}, REPO, SITE_URL, None) == ["catalog lists no model sources"]


def test_csp_checks():
    assert hc.csp_problems(CSP, CSP) == []
    assert hc.csp_problems(None, CSP) == ["no Content-Security-Policy header"]
    assert any("other origins" in p for p in hc.csp_problems(CSP + "; img-src https://cdn.example.com", None))
    assert any("frame-ancestors" in p for p in hc.csp_problems("default-src 'self'; connect-src 'self'", None))
    assert any("differs" in p for p in hc.csp_problems(CSP, CSP + " "))


def resp(**h: str) -> object:
    return hc.Resp(200, {k.replace("_", "-"): [v] for k, v in h.items()}, b"")


def test_header_checks():
    good = dict(content_security_policy=CSP, x_content_type_options="nosniff", referrer_policy="no-referrer",
                permissions_policy="browsing-topics=()")
    assert hc.header_problems(resp(**good), CSP) == []
    assert any("cookie" in p for p in hc.header_problems(resp(**good, set_cookie="a=b"), CSP))
    assert any("x-content-type-options" in p for p in hc.header_problems(resp(**{**good, "x_content_type_options": "x"}), CSP))
    missing = dict(good)
    del missing["referrer_policy"]
    assert any("referrer-policy" in p for p in hc.header_problems(resp(**missing), CSP))


@pytest.mark.parametrize("path,ctype,ok", [
    ("/", "text/html; charset=utf-8", True), ("/appcast.xml", "application/xml", True),
    ("/appcast.xml", "text/html", False), ("/catalog/v2/catalog.json", "application/json; charset=utf-8", True),
    ("/catalog/v2/catalog.json", "text/plain", False), ("/.well-known/security.txt", "text/plain; charset=utf-8", True),
    ("/.well-known/security.txt", "application/octet-stream", False), ("/x.json.sig", "text/html", False),
    ("/x.json.sig", "application/pgp-signature", True)])
def test_content_types(path, ctype, ok):
    assert hc.type_ok(path, ctype) is ok


# ---- end to end against a throwaway dist ----

def make_dist(tmp: Path, *, csp: str = CSP, cat: dict | None = None) -> Path:
    d = tmp / "dist"
    for p in ["", "download", "help/faq", "legal/privacy", "legal/terms"]:
        (d / p).mkdir(parents=True, exist_ok=True)
        (d / p / "index.html").write_text("<!doctype html><title>x</title>")
    (d / "404.html").write_text("<!doctype html><title>404</title>")
    (d / "appcast-dev.xml").write_text(feed("http://192.168.64.1:8765/AntiChat.dmg"))
    (d / "catalog/v2").mkdir(parents=True)
    body = json.dumps(cat or catalog())
    (d / "catalog/v2/catalog.json").write_text(body)
    (d / "catalog/v2/3.json").write_text(body)
    (d / "catalog/v2/catalog.json.sig").write_bytes(b"\x00sig")
    (d / ".well-known").mkdir()
    (d / ".well-known/security.txt").write_text("Contact: mailto:x@y\nExpires: 2099-01-01T00:00:00Z\n")
    (d / "oauth").mkdir()
    (d / "oauth/mcp-client-metadata.json").write_text("{}")
    headers = [{"key": "Content-Security-Policy", "value": csp}, {"key": "Referrer-Policy", "value": "no-referrer"},
               {"key": "X-Content-Type-Options", "value": "nosniff"},
               {"key": "Permissions-Policy", "value": "browsing-topics=()"}]
    (d / "vercel.json").write_text(json.dumps({"headers": [{"source": "/(.*)", "headers": headers}]}))
    return d


def run_local(dist: Path, dev: bool = True) -> object:
    rep = hc.Report()
    s, base = srv_mod.serve(dist)
    try:
        hc.run(base, remote=False, dist=dist, dev=dev, rep=rep)
    finally:
        s.shutdown()
    return rep


def test_local_good_site_passes(tmp_path):
    rep = run_local(make_dist(tmp_path))
    assert rep.failed == []
    assert any("HTTPS" in p for p in rep.pending) and any("appcast.xml" in p for p in rep.pending)


def test_local_seeded_third_party_csp_fails(tmp_path):
    rep = run_local(make_dist(tmp_path, csp=CSP + "; script-src https://cdn.example.com"))
    assert any("other origins" in f for f in rep.failed)


def test_local_seeded_unpinned_catalog_fails(tmp_path):
    rep = run_local(make_dist(tmp_path, cat=catalog("https://huggingface.co/o/r/resolve/main/m.gguf")))
    assert any("catalog.json" in f for f in rep.failed)


def test_local_dev_runtime_fails_without_dev(tmp_path):
    rep = run_local(make_dist(tmp_path, cat=catalog(runtime="http://localhost:4321/rt.zip")), dev=False)
    assert any("runtimes.rt" in f for f in rep.failed)


def test_local_missing_headers_config_fails(tmp_path):
    d = make_dist(tmp_path)
    (d / "vercel.json").unlink()
    rep = run_local(d)
    assert any("vercel.json present" in f for f in rep.failed)
    assert any("no Content-Security-Policy" in f for f in rep.failed)


def test_serve_site_routing(tmp_path):
    d = make_dist(tmp_path)
    s, base = srv_mod.serve(d)
    try:
        assert hc.fetch(base + "/legal/terms").status == 200
        assert hc.fetch(base + "/nope/").status == 404
        assert hc.fetch(base + "/vercel.json").status == 404  # config is not served
        assert hc.fetch(base + "/../../etc/passwd").status == 404
        r = hc.fetch(base + "/appcast-dev.xml")
        assert r.h("content-type") == "application/xml" and r.h("x-content-type-options") == "nosniff"
    finally:
        s.shutdown()


class _Remote(BaseHTTPRequestHandler):
    """A deployed host done wrong: plain http, redirects off-host, a cookie, an SPA fallback."""

    def do_GET(self):  # noqa: N802
        if self.path == "/legal/terms":
            self.send_response(301)
            self.send_header("Location", "http://other.example.invalid/legal/terms/")
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Set-Cookie", "id=1")
        self.end_headers()
        self.wfile.write(b"<html></html>")

    def log_message(self, *a):  # noqa: ANN002
        pass


def test_url_mode_flags_a_bad_host():
    s = ThreadingHTTPServer(("127.0.0.1", 0), _Remote)
    threading.Thread(target=s.serve_forever, daemon=True).start()
    try:
        rep = hc.Report()
        hc.run(f"http://127.0.0.1:{s.server_address[1]}", remote=True, dist=None, dev=False, rep=rep)
    finally:
        s.shutdown()
    text = "\n".join(rep.failed)
    for want in ["base URL is https", "redirects to https", "Strict-Transport-Security", "sets a cookie",
                 "unknown path → 404", "/legal/terms (no trailing slash)", "appcast.xml enclosures",
                 "Content-Type text/html"]:
        assert want in text, want
