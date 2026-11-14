#!/usr/bin/env python3
"""M7.T01 (AT-253, R-253 AC1): `fixtures/catalog/catalog-search-swap.json` = catalog-valid.json + catalog_version 120 +
a `search_engines` section that disables Mojeek and changes Startpage's `items` XPath, signed with test key A by
`catalog-tool sign --cryptokit`. The bad-signature half reuses `catalog-bad-sig.json`. Run with `python3 -I`.

  tools/fixtures/make-catalog-search-swap.py [--fixtures DIR]
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
NEW_STARTPAGE_ITEMS = "//section[contains(@class, 'w-gl')]/div[./a]"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--fixtures", default=str(ROOT / "fixtures"))
    a = ap.parse_args()
    cat = Path(a.fixtures) / "catalog"
    m = json.loads((cat / "catalog-valid.json").read_text())
    m["catalog_version"] = 120
    m["search_engines"] = [
        {"id": "mojeek", "name": "Mojeek", "enabled": False, "kind": "html", "parser": "xpath",
         "url_template": "https://www.mojeek.com/search?q={q}",
         "xpaths": {"items": "//ul[contains(@class, 'results')]/li", "title": ".//h2//text()", "href": ".//h2/a/@href",
                    "body": ".//p[@class='s']//text()"},
         "safe_param": {"off": "safe=0", "on": "safe=1"}, "min_app_version": "0.1.0"},
        {"id": "startpage", "name": "Startpage", "enabled": True, "kind": "html", "parser": "xpath",
         "url_template": "https://www.startpage.com/sp/search?query={q}&cat=web&t=device&lui=english&language=english&segment=organic",
         "xpaths": {"items": NEW_STARTPAGE_ITEMS, "title": ".//h2//text()", "href": "./a/@href", "body": ".//p//text()"},
         "safe_param": {"off": "qadf=none", "on": "qadf=heavy"},
         "drop_url_prefixes": ["https://www.google.com"], "min_app_version": "0.1.0"},
    ]
    out = cat / "catalog-search-swap.json"
    out.write_text(json.dumps(m, indent=2, sort_keys=True, ensure_ascii=False) + "\n")
    subprocess.run(["swift", "run", "-q", "catalog-tool", "sign", str(out), "--key-file", str(cat / "test-keys/catalog-a.priv"),
                    "--cryptokit"], cwd=ROOT, check=True)
    # The page the new XPath matches (structure only; synthetic, CC0).
    page = ('<html><body><section class="w-gl"><div><a href="https://swap.test/new"><h2>Swapped XPath hit</h2></a>'
            '<p>matched by the catalog XPath</p></div></section></body></html>\n')
    (cat / "catalog-search-swap.startpage.html").write_text(page)
    print(f"wrote {out} (+ .sig, + catalog-search-swap.startpage.html)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
