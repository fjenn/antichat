# File tools runtime (`filetools-runtime`)

The Python that `run_python` executes (R-018, G-027; M6.T15–T19). A downloadable **runtime component**
(architecture §9.1): never in the app bundle, installed by `RuntimeInstaller` into
`~/Library/Application Support/AntiChat/Runtimes/filetools-runtime@<ver>/` (Debug: `AntiChat-Dev/`), read-only to
the sandboxed `AntiChatFileTools.xpc` (A-M6-11).

## Provenance

| Input | Pin | Licence |
|---|---|---|
| Interpreter + stdlib | `beeware/Python-Apple-support@2a786c1994`, release `3.13-b18`, `Python-3.13-macOS-support.b18.tar.gz`, sha256 in `base.sha256` (P-files-tools-09). Python 3.13.17 (framework Info.plist, `sys.version`). | MIT (packaging), PSF-2.0 (CPython), OpenSSL Apache-2.0 |
| Wheels | `requirements.in` (exact pins) → `requirements.lock` (`uv pip compile --generate-hashes`, binary wheels only, `aarch64-apple-darwin`, Python 3.13), installed with `--require-hashes` | table below |
| Launcher | `launcher/ft-python.c` (ours): `Py_BytesMain` against `Python.framework` | GPL-3.0 (this repo) |
| Process setup + REPL | `sitecustomize.py`, `repl.py` (ours) | GPL-3.0 (this repo) |

Wheel licences (from each `*.dist-info/METADATA`, `License-Expression` or the licence classifier):

| Distribution | Version | Licence |
|---|---|---|
| contourpy | 1.4.0 | BSD-3-Clause |
| cycler | 0.12.1 | BSD |
| et_xmlfile | 2.0.0 | MIT |
| fonttools | 4.68.0 | MIT |
| kiwisolver | 1.5.1 | BSD |
| lxml | 6.1.3 | BSD-3-Clause |
| matplotlib | 3.11.2 | PSF-based (matplotlib licence) |
| numpy | 2.5.4 | BSD-3-Clause AND 0BSD AND MIT AND Zlib AND CC0-1.0 |
| openpyxl | 3.1.5 | MIT |
| packaging | 26.3 | Apache-2.0 OR BSD-2-Clause |
| pandas | 3.1.1 | BSD-3-Clause |
| pillow | 13.0.0 | MIT-CMU |
| pyparsing | 3.3.3 | MIT |
| pypdf | 6.21.4 | BSD-3-Clause |
| python-dateutil | 4.0.0 | BSD-3-Clause |
| python-docx | 1.2.0 | MIT |
| python-pptx | 1.0.2 | MIT |
| typing_extensions | 4.16.0 | PSF-2.0 |
| tzdata | 2026.6 | Apache-2.0 |
| xlsxwriter | 3.3.1 | BSD-2-Clause |

No PyMuPDF (AGPL, excluded), no compilers, no pip in the runtime.

## Layout

```
bin/ft-python                                  launcher (LC_RPATH @executable_path/.. = runtime root)
Python.framework/Versions/3.13/Python          libpython (arm64 slice only)
Python.framework/Versions/3.13/lib/python3.13  stdlib (no test/, idlelib, ensurepip, curses, tkinter)
site-packages/                                 wheels; tests/, *.pyi, headers, console scripts removed
antichat/sitecustomize.py                      Agg backend, MPLCONFIGDIR in scratch, figure save, audit hook
antichat/repl.py                               JSON-lines REPL ({"id","code"} → {"id","stdout","stderr","error","files"})
RUNTIME.json                                   name, version, inputs and their hashes
```

Every `.py` is precompiled (`--invalidation-mode unchecked-hash`): a sandboxed run never writes `__pycache__` into
the signed tree (Apple forum 758706); the launcher env also sets `PYTHONDONTWRITEBYTECODE=1`.

## Build

```
make runtime-filetools            # → build/runtimes/filetools-runtime-<ver>.zip + .json manifest + build/at/AT-018/<date>/size.json
make runtime-filetools CHECK=1    # verify: base hash, lock current, uv pip sync --require-hashes, zip vs manifest
make runtime-filetools LOCK=1     # re-lock after editing requirements.in (needs PyPI)
```

The zip is byte-reproducible (fixed mtimes, sorted entries, `zip -X`; `ditto` zips are not). Signing, the
catalog entry and the install are M6.T16 (`tools/release/sign-runtime.sh`, `catalog/runtimes.yaml`).

Bump: new Python-Apple-support `b<N>` → update `base.sha256` (URL + sha256 from the release API) and the version
strings in `build.sh`; new wheels → edit `requirements.in`, `LOCK=1`, rebuild, run the File tools suites
(`FileToolsJailTests`, `SecuritySuiteTests`).
