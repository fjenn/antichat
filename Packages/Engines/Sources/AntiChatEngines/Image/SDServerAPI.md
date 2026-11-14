# sd-server: launch flags and HTTP field mapping (M4.T05/T06)

Pin: `leejet/stable-diffusion.cpp@e239e4b0fd3de49834cec67031a44796ca465abc` (`Binaries/sdcpp`), built by
`tools/binaries/build.sh` (target `sd-server`, `examples/server/CMakeLists.txt`) with the UP-SD patches of
`Vendor/patches/sdcpp/` applied to a copy, signed by `tools/release/sign.sh` (`Contents/Helpers/sd-server`,
entitlements `sd-server.plist`). It runs as a child of the engine helper (D-013) under `SDServerSupervisor`.

## Launch (`SDServerSupervisor.arguments`)

| Flag | Value | Source at the pin |
|---|---|---|
| `--listen-ip unix:<dir>/sd.sock` | unix-domain socket in a fresh 0700 dir per launch (UP-SD-001; no TCP/UDP socket) | `examples/server/main.cpp:170-171` (patched), `thirdparty/httplib.h:4227-4265` (AF_UNIX bind) |
| `--listen-port 80` | unused for a unix socket (UP-SD-001 passes a fixed non-zero port: httplib’s port-0 lookup has no AF_UNIX case) | `examples/server/runtime.cpp:353,386` |
| `--model-dir <empty private dir>` | the catalog root; models come from the flags below, sd-server never downloads | `examples/server/runtime.cpp` |
| `--diffusion-model <gguf>` | `ImageModelSet.diffusionModel` | `examples/common/common.cpp:451` |
| `--llm <gguf>` | text encoder (`img-te`, `img-edit-te`) | `examples/common/common.cpp:426` |
| `--llm_vision <gguf>` | mmproj of `img-edit-te` (A-M4-04) | `examples/common/common.cpp:436` |
| `--vae <safetensors>` | `img-vae-flux2` / `img-vae-qwen` | `examples/common/common.cpp:471` |
| `--model-args k=v` | catalog `model_args` (`qwen_image_zero_cond_t=true` for img-edit) | `examples/common/common.cpp:536` |
| `-t <n>` | performance cores (M4.T06) | `examples/common/common.cpp:587` |

Environment: inherited minus `HF_TOKEN`, `HUGGING_FACE_HUB_TOKEN` and the proxy variables. Readiness:
`GET /sdcpp/v1/models/status` → `state == "ready"` (10 s budget after the weights are mapped; the model load
itself is bounded by the supervisor's `timeout`). Teardown: SIGTERM to the process group → 3 s → SIGKILL, plus the
`LlamaWatchdog` orphan guard. Crash → `engine.restarted`; the next job relaunches it (NFR-S4).

## HTTP (`SDServerClient`, over `UnixHTTPClient.fetch`)

| Route | Use | api.md |
|---|---|---|
| `POST /sdcpp/v1/img_gen` → 202 `{id}` | submit (prompt, negative_prompt, width, height, seed, batch_count 1, `sample_params{sample_method, sample_steps, guidance.txt_cfg}`, `init_image`, `mask_image`, `ref_images`, `preview`, `preview_interval 1`, `output_format png`, `embed_image_metadata false`) | `:1003`, body `:1102-1185` |
| `GET /sdcpp/v1/jobs/{id}` | `status` queued/generating/completed/failed/cancelled; `preview{pass, step, total_steps, b64_json}` (latest frame only); `result.images[].b64_json` | `:1031`, job model `:737-797` |
| `POST /sdcpp/v1/jobs/{id}/cancel` | cooperative cancel at the next sampling checkpoint | `:1087` |
| `POST /sdcpp/v1/models/load` / `unload` | load / release the context without restarting the process | `:88-89` |
| `POST /sdcpp/v1/upscale` | M11 (variants + upscale moved, D-026) | `:1041` |
| `GET /sdcpp/v1/models/status` | readiness | "Model management" `:62` |

Every decoded preview and the final PNG go to `MediaJobOutputs` (the MediaJobRunner's gate) — the client and the
runtime never write a generated image (M4.T04, R-285).
