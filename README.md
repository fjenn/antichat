# AntiChat

**A free, private ChatGPT-style AI that runs on your iPhone.**

AntiChat looks and feels like the chat apps you know, but the AI model runs on the phone itself. No account,
no subscription, no ads, no tracking, and it keeps working in airplane mode. When you are online, it can also
search the web and use the apps you connect.

[Privacy policy](https://opena.tech/antichat/privacy) · [Support](https://opena.tech/antichat/support) · [Issues](https://github.com/fjenn/antichat/issues)

## Features

- **Chat on the phone:** streaming answers with Markdown, code, tables and math; copy, select text, try again,
  edit, branch and compare answer versions.
- **History:** a drawer with search, pin, archive, rename, share/export and Face ID lock for chats.
- **Works offline:** chat, history, search and dictation need no connection; online tools come back by themselves.
- **Model store:** one tap picks the right model for your phone; or choose Faster, Smarter or (18+, opt-in) Unrestricted models.
- **Memory and personalization:** custom instructions and memories, kept on the phone.
- **Dictation:** speech to text on the device.
- **Web search** (optional): answers with sources, from several search engines.
- **Connectors** (optional): Gmail, Calendar, Notion and more through Composio, or your own MCP servers; AntiChat asks before it writes or sends anything.

## Privacy

AntiChat collects no data. Chats, memories, settings and models stay on your phone, and the developer never
receives them. The app goes online only for what you ask for: downloading a model (Hugging Face), web search
(your search words go to the search providers), weather and places (Open-Meteo, OpenStreetMap; your location only
if you allow it), and connected apps (through a small relay and Composio, only once you connect an app).
Details: [opena.tech/antichat/privacy](https://opena.tech/antichat/privacy).

## How the model is picked

Models are GGUF files run by [llama.cpp](https://github.com/ggml-org/llama.cpp) through
[llama.rn](https://github.com/mybigday/llama.rn). The catalogue (`src/antichat/engine/models/catalog/`) is a
signed list of evaluated models grouped into classes (Fast, Smart, …). On first launch AntiChat measures how much
memory the app can really use on this phone, starts from the default for the phone's class and walks down the
ladder until a model fits, trying smaller contexts and dropping the vision part before giving up on a model
(`src/antichat/engine/models/policy/select.ts`). After loading, it measures real generation speed and offers a
smaller model once if the phone is too slow; under memory pressure it sheds helper models first. The store shows
the same fit labels (Runs great / Runs OK / Too large) from the same measured budget.

## Build for iOS

Requirements: macOS with Xcode 26 or later, Node 22.21+ (`.nvmrc`), Yarn 1, Ruby with Bundler, CocoaPods.

```sh
yarn install
cp .env.example .env               # defaults are fine; accounts and PalsHub are off
cd ios && bundle install && bundle exec pod install && cd ..

# Simulator, JS bundle embedded (no Metro needed)
tools/antichat/build-ios-debug.sh sim
xcrun simctl install booted ios/build/Build/Products/Debug-iphonesimulator/PocketPal.app

# Or the usual React Native dev loop
yarn start
yarn ios
```

For a real iPhone, set your own team: `ruby tools/antichat/add-ios-files.rb <your Apple team id>` (needs the
`xcodeproj` gem), then `tools/antichat/build-ios-debug.sh device <udid>`. The extended-memory entitlements need a
paid developer account; `ANTICHAT_NO_ENTITLEMENTS=1` builds without them. Connectors use the hosted AntiChat relay;
set `ANTICHAT_RELAY_URL` at bundle time to point a build at your own.

Checks: `yarn lint`, `yarn typecheck`, `npx jest src/antichat`.

AntiChat's own code lives in `src/antichat/`, `ios/AntiChat/` and `android/.../antichat/`; edits to PocketPal
files are marked `ANTICHAT:` and listed in `docs/UPSTREAM-PATCHES.md` (rules in `docs/antichat/FORK.md`). The
Android build exists but the iPhone app is the focus.

## Credits

- [PocketPal AI](https://github.com/a-ghorbani/pocketpal-ai) by Asghar Ghorbani: the app AntiChat is forked from (MIT).
- [llama.cpp](https://github.com/ggml-org/llama.cpp) and [llama.rn](https://github.com/mybigday/llama.rn): on-device inference.
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) and [whisper.rn](https://github.com/mybigday/whisper.rn): dictation.
- [Off Grid](https://github.com/off-grid-ai/OGAM): model-loading fallback chain (ported, MIT).
- [Composio](https://composio.dev): connectors. The open models in the catalogue belong to their authors and keep their own licences.
- React Native, Reanimated, Keyboard Controller, LegendList, op-sqlite, Unistyles, Lucide and the other packages in [NOTICE.md](NOTICE.md).

## Licence

MIT, see [LICENSE](LICENSE). Third-party notices: [NOTICE.md](NOTICE.md).
