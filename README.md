# AntiChat

Your own AI, on your Mac. Chat, talk, make pictures and short videos with AI that runs on your Mac's own chip.
Private, free, and no account.

**Download:** [antichat.ai](https://antichat.ai) · [Releases](https://github.com/fjenn/antichat/releases/latest)

## What it does

- **Chat:** write, plan, explain and code. Drop in PDFs, spreadsheets and documents, and get files, charts and
  diagrams back. Python runs on your Mac in a sealed sandbox.
- **Voice:** talk it through hands-free; it listens, thinks and answers out loud.
- **Photo:** make pictures from a sentence, then edit, erase, cut out and upscale them.
- **Video:** short clips from a sentence or a picture, rendered on your Mac.
- **Evil Mode** (off by default, 18+): uncensored models with near-zero refusals.
- Projects, memory, skills, incognito chats, a quick panel over any app, and optional web search and connections
  (Gmail, Calendar, GitHub, Notion and more) that stay off until you turn them on.

Everything runs locally. Once the models are downloaded, turn on *Offline only* and nothing leaves your Mac.
No telemetry, no analytics, no account.

## Requirements

- A Mac with Apple silicon
- macOS 26 or later
- Disk space for the models you choose (setup shows each size before anything downloads)

## Building from source

You need Xcode 27. `make bootstrap` downloads every other tool it needs, pinned by checksum.

```sh
git clone --recurse-submodules https://github.com/fjenn/antichat.git
cd antichat
make bootstrap   # toolchain, helper binaries (llama.cpp, stable-diffusion.cpp) and checks
make build       # Debug app → build/AntiChat.app
make run
```

`make test-unit` runs the unit tests. Some integration, quality and benchmark suites use a large private
fixtures set (recorded web pages, audio datasets) that is not part of this repository; those suites skip or fail
without it.

### Layout

| Path | What's there |
| --- | --- |
| `App/` | The macOS app target, UI tests and integration tests |
| `Packages/` | Swift packages: UI, design system, harness, engines, tools, storage, network, platform |
| `Binaries/` | llama.cpp and stable-diffusion.cpp (submodules) and their pinned checksums |
| `Runtimes/` | Python runtimes for video generation and file tools |
| `Vendor/` | Vendored third-party code, pinned by commit |
| `catalog/` | The signed model catalog |
| `relay/` | The small server that brokers optional connections (Composio) |
| `tools/` | Build, release, test and benchmark tooling |
| `docs/` | Product requirements and build plans |

### Forks

Forks replace the hosts in `Config/Hosting.json` (applied with `tools/release/set-hosting.py`) and the public keys
in `Config/Keys.release.plist`, then rebuild. No code change is needed.

## License

AntiChat's own code is released under the [MIT License](LICENSE). Third-party components, vendored code and
models keep their own licenses; see [ACKNOWLEDGMENTS.md](ACKNOWLEDGMENTS.md).
