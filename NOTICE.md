# Notices

AntiChat for iPhone is a fork of [PocketPal AI](https://github.com/a-ghorbani/pocketpal-ai)
(MIT, Copyright (c) 2024 Asghar Ghorbani). PocketPal's licence and copyright notice are kept in
[LICENSE](LICENSE).

Parts of the model-loading fallback chain are ported from
[Off Grid](https://github.com/off-grid-ai/OGAM) (MIT, (c) Mohammed Ali Chherawalla);
the source files that contain ported code say so.

AI models are not part of this repository. The app downloads them on request from Hugging Face; each
model keeps its own licence (Apache-2.0, MIT, Gemma terms, LFM Open License and others), which the
app shows before the download and in Settings > About.

## Third-party packages

The app's direct dependencies are listed below. The full list, with every transitive package,
its copyright lines and licence text, ships in the app (Settings > About > Open-source licences)
and lives in [src/antichat/ui/settings/about/licences.json](src/antichat/ui/settings/about/licences.json).

| Package | Version | Licence |
|---|---|---|
| [@callstack/liquid-glass](https://github.com/callstack/liquid-glass#readme) | 0.8.2 | MIT |
| [@dr.pogodin/react-native-fs](https://dr.pogodin.studio/docs/react-native-file-system) | 2.36.0 | MIT |
| [@flyerhq/react-native-link-preview](https://github.com/flyerhq/react-native-link-preview#readme) | 1.6.0 | MIT |
| [@fugood/react-native-audio-pcm-stream](https://github.com/mybigday/react-native-audio-pcm-stream) | 1.1.4 | MIT |
| [@gorhom/bottom-sheet](https://gorhom.dev/react-native-bottom-sheet/) | 5.2.14 | MIT |
| [@hookform/resolvers](https://react-hook-form.com) | 5.2.2 | MIT |
| [@invertase/react-native-apple-authentication](https://github.com/invertase/react-native-apple-authentication) | 2.5.1 | Apache-2.0 |
| [@legendapp/list](https://github.com/LegendApp/legend-list#readme) | 3.9.0 | MIT |
| [@lodev09/react-native-true-sheet](https://sheet.lodev09.com) | 4.1.2 | MIT |
| [@nozbe/watermelondb](https://github.com/Nozbe/WatermelonDB#readme) | 0.28.0 | MIT |
| [@op-engineering/op-sqlite](https://github.com/OP-Engineering/op-sqlite#readme) | 19.0.6 | MIT |
| [@pocketpalai/react-native-speech](https://github.com/a-ghorbani/react-native-speech#readme) | 2.11.4 | MIT |
| [@pocketpalai/react-native-speech-phonon](https://github.com/a-ghorbani/react-native-speech/tree/main/packages/react-native-speech-phonon#readme) | 0.2.2 | MIT |
| [@react-native-ai/apple](https://github.com/callstackincubator/ai#readme) | 0.13.0 | MIT |
| [@react-native-async-storage/async-storage](https://github.com/react-native-async-storage/async-storage#readme) | 2.2.0 | MIT |
| [@react-native-clipboard/clipboard](https://github.com/react-native-clipboard/clipboard#readme) | 1.16.3 | MIT |
| [@react-native-community/geolocation](https://github.com/michalchudziak/react-native-geolocation#README.md) | 3.4.0 | MIT |
| [@react-native-community/netinfo](https://github.com/react-native-netinfo/react-native-netinfo#readme) | 12.0.1 | MIT |
| [@react-native-community/slider](https://github.com/callstack/react-native-slider#readme) | 5.0.1 | MIT |
| [@react-native-documents/picker](https://github.com/react-native-documents/document-picker#readme) | 11.0.4 | MIT |
| [@react-native-firebase/app](https://github.com/invertase/react-native-firebase/tree/main/packages/app) | 23.5.0 | Apache-2.0 |
| [@react-native-firebase/app-check](https://github.com/invertase/react-native-firebase/tree/main/packages/app-check) | 23.5.0 | Apache-2.0 |
| [@react-native-google-signin/google-signin](https://github.com/react-native-google-signin/google-signin#readme) | 16.0.0 | MIT |
| [@react-native-masked-view/masked-view](https://github.com/react-native-masked-view/masked-view#readme) | 0.3.2 | MIT |
| [@react-native-menu/menu](https://github.com/react-native-menu/menu#readme) | 2.3.3 | MIT |
| [@react-native-picker/picker](https://github.com/react-native-picker/picker#readme) | 2.11.4 | MIT |
| [@react-navigation/drawer](https://reactnavigation.org/docs/drawer-navigator/) | 7.14.4 | MIT |
| [@react-navigation/native](https://reactnavigation.org) | 7.5.1 | MIT |
| [@react-navigation/stack](https://reactnavigation.org/docs/stack-navigator/) | 7.12.1 | MIT |
| [@sbaiahmed1/react-native-blur](https://github.com/sbaiahmed1/react-native-blur#readme) | 6.0.3 | MIT |
| [@supabase/supabase-js](https://github.com/supabase/supabase-js/tree/master/packages/core/supabase-js) | 2.75.1 | MIT |
| [axios](https://axios-http.com) | 1.12.2 | MIT |
| [buffer](https://github.com/feross/buffer) | 5.7.1 | MIT |
| [buffer](https://github.com/feross/buffer) | 6.0.3 | MIT |
| [chat-formatter](https://github.com/a-ghorbani/chat-formatter) | 0.3.4 | MIT |
| [date-fns](https://github.com/date-fns/date-fns) | 4.1.0 | MIT |
| [dayjs](https://day.js.org) | 1.11.18 | MIT |
| [expr-eval](https://github.com/silentmatt/expr-eval#readme) | 2.0.2 | MIT |
| [fflate](https://101arrowz.github.io/fflate) | 0.8.3 | MIT |
| [jsonrepair](https://github.com/josdejong/jsonrepair) | 3.15.0 | ISC |
| [llama.rn](https://github.com/mybigday/llama.rn#readme) | 0.13.0-rc.11 | MIT |
| [lucide-react-native](https://lucide.dev) | 1.79.0 | ISC |
| [minisearch](https://lucaong.github.io/minisearch/) | 7.2.0 | MIT |
| [mobx](https://mobx.js.org/) | 6.15.0 | MIT |
| [mobx-persist-store](https://github.com/quarrant/mobx-persist-store#readme) | 1.1.8 | MIT |
| [mobx-react](https://mobx.js.org) | 9.2.1 | MIT |
| [mustache](https://github.com/janl/mustache.js) | 4.2.0 | MIT |
| [onnxruntime-react-native](https://github.com/microsoft/onnxruntime/blob/main/js/react_native/README.md) | 1.24.3 | MIT |
| [pinyin-pro](https://pinyin-pro.cn) | 3.28.1 | MIT |
| [prop-types](https://facebook.github.io/react/) | 15.8.1 | MIT |
| [react](https://react.dev/) | 19.2.3 | MIT |
| [react-hook-form](https://react-hook-form.com) | 7.65.0 | MIT |
| [react-native](https://reactnative.dev/) | 0.87.1 | MIT |
| [react-native-audio-api](https://github.com/software-mansion/react-native-audio-api#readme) | 1.0.1 | MIT |
| [react-native-code-highlighter](https://github.com/gmsgowtham/react-native-code-highlighter#readme) | 1.3.0 | MIT |
| [react-native-config](https://github.com/luggit/react-native-config) | 1.5.5 | MIT |
| [react-native-device-info](https://github.com/react-native-device-info/react-native-device-info#readme) | 14.1.1 | MIT |
| [react-native-enriched-markdown](https://enriched.swmansion.com/markdown) | 1.3.0-nightly-20261123-3a2c1ade8 | MIT |
| [react-native-gesture-handler](https://docs.swmansion.com/react-native-gesture-handler/) | 3.5.0 | MIT |
| [react-native-get-random-values](https://github.com/LinusU/react-native-get-random-values) | 1.11.0 | MIT |
| [react-native-haptic-feedback](https://github.com/mkuczera/react-native-haptic-feedback) | 2.3.3 | MIT |
| [react-native-iap](https://github.com/hyodotdev/openiap/tree/main/libraries/react-native-iap) | 16.6.2 | MIT |
| [react-native-image-picker](https://github.com/react-native-image-picker/react-native-image-picker) | 8.2.1 | MIT |
| [react-native-image-viewing](https://github.com/jobtoday/react-native-image-viewing#readme) | 0.2.2 | MIT |
| [react-native-inappbrowser-reborn](https://github.com/proyecto26/react-native-inappbrowser) | 3.7.1 | MIT |
| [react-native-keyboard-controller](https://kirillzyusko.github.io/react-native-keyboard-controller/) | 1.24.0 | MIT |
| [react-native-keychain](https://oblador.github.io/react-native-keychain) | 10.0.0 | MIT |
| [react-native-linear-gradient](https://github.com/react-native-linear-gradient/react-native-linear-gradient) | 2.8.3 | MIT |
| [react-native-localize](https://github.com/zoontek/react-native-localize) | 3.8.0 | MIT |
| [react-native-nitro-modules](https://nitro.margelo.com) | 0.37.2 | MIT |
| [react-native-notify-kit](https://github.com/marcocrupi/react-native-notify-kit#readme) | 10.10.1 | Apache-2.0 |
| [react-native-paper](https://callstack.github.io/react-native-paper) | 5.15.3 | MIT |
| [react-native-parsed-text](https://github.com/taskrabbit/react-native-parsed-text#readme) | 0.0.22 | MIT |
| [react-native-permissions](https://github.com/zoontek/react-native-permissions#readme) | 5.6.0 | MIT |
| [react-native-picker-select](https://github.com/lawnstarter/react-native-picker-select) | 9.3.1 | MIT |
| [react-native-pulsar](https://github.com/software-mansion/pulsar#readme) | 1.7.0 | MIT |
| [react-native-reanimated](https://docs.swmansion.com/react-native-reanimated) | 4.8.0 | MIT |
| [react-native-safe-area-context](https://github.com/AppAndFlow/react-native-safe-area-context#readme) | 5.10.1 | MIT |
| [react-native-screens](https://github.com/software-mansion/react-native-screens#readme) | 4.30.0 | MIT |
| [react-native-share](https://react-native-share.github.io/react-native-share/) | 12.2.0 | MIT |
| [react-native-svg](https://github.com/software-mansion/react-native-svg) | 15.16.0 | MIT |
| [react-native-tcp-socket](https://github.com/Rapsssito/react-native-tcp-socket) | 6.4.3 | MIT |
| [react-native-teleport](https://kirillzyusko.github.io/react-native-teleport/) | 1.2.5 | MIT |
| [react-native-unistyles](https://github.com/jpudysz/react-native-unistyles#readme) | 3.8.2 | MIT |
| [react-native-url-polyfill](https://github.com/charpeni/react-native-url-polyfill) | 3.0.0 | MIT |
| [react-native-vector-icons](https://github.com/oblador/react-native-vector-icons) | 10.3.0 | MIT |
| [react-native-vision-camera](https://react-native-vision-camera.com/) | 4.7.2 | MIT |
| [react-native-webview](https://github.com/react-native-webview/react-native-webview#readme) | 13.16.1 | MIT |
| [react-native-worklets](https://docs.swmansion.com/react-native-worklets) | 0.14.0 | MIT |
| [react-native-zoom-toolkit](https://glazzes.github.io/react-native-zoom-toolkit/) | 5.1.1 | MIT |
| [react-syntax-highlighter](https://github.com/react-syntax-highlighter/react-syntax-highlighter#readme) | 15.6.6 | MIT |
| [tweetnacl](https://tweetnacl.js.org) | 1.0.3 | Unlicense |
| [uuid](https://github.com/uuidjs/uuid) | 13.0.0 | MIT |
| [whisper.rn](https://github.com/mybigday/whisper.rn#readme) | 0.7.4 | MIT |
| [zod](https://zod.dev) | 4.1.12 | MIT |
| [zod](https://zod.dev) | 4.6.7 | MIT |
