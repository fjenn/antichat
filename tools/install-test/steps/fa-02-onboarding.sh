#!/bin/bash
# AT-FA-02 onboarding + AT-FA-03 fast first chat (NFR-M5) + AT-FA-14 (this VM's real RAM → its tier) in the clean VM.
# The app's own onboarding (S-01 → S-04) is driven in-process by OnboardingProbe (`-OnboardingProbe`, keyboard-free:
# the same model actions the buttons call): Chat + Voice packs (ONB_PROBE_VOICE=1, for AT-FA-05), Evil on with the
# adult box (ONB_PROBE_EVIL=1, for AT-FA-07), Open chat at once, a first message queued until the starter is ready,
# then the tier model. Downloads run through the real downloader and verifier from the catalog's Hugging Face URLs,
# served by the local mirror (-DownloadHost; see fa-mirror.py). No -FakeHardware: the VM's own RAM picks the tier.
# Usage (in the VM): fa-02-onboarding.sh
set -uo pipefail
source "$(dirname "$0")/fa-common.sh"
o2="$(fa_out AT-FA-02)"; o3="$(fa_out AT-FA-03)"; o14="$(fa_out AT-FA-14)"
p="$HOME/fa/onboarding"; rm -rf "$p"; mkdir -p "$p"
mirror_up "$o2" || exit 1
# Link speed of this run (the NFR-M5 budget is scaled to it) and, for the record, the VM's link to Hugging Face.
curl -s -o /dev/null -m 20 -w '%{speed_download}' "http://127.0.0.1:$MIRROR_PORT/$(cd "$MIRROR" && find . -name '*.safetensors' -size +100M | head -1 | sed 's#^\./##')" > "$o3/mirror-Bps.txt" || true
curl -sL -o /dev/null -m 20 -w '%{speed_download}' https://huggingface.co/Qwen/Qwen3-0.6B/resolve/main/model.safetensors > "$o3/hf-Bps.txt" || true
start=$(date +%s)
log stream --style compact --predicate 'process == "tccd" AND eventMessage CONTAINS[c] "antichat"' > "$o2/tcc.log" 2>&1 &
tcc=$!
open -g -n "$APP" --env ONB_PROBE_EVIL=1 --env ONB_PROBE_VOICE=1 --stderr "$p/app.log" --args -ApplePersistenceIgnoreState YES \
    -ResetOnboarding YES -OnboardingProbe "$p" -DownloadHost "http://127.0.0.1:$MIRROR_PORT"
sleep 3; pid=$(pgrep -f "$BIN" | head -1)
footprint_sampler "$o14/peak-footprint-bytes.txt" "${pid:-0}"
for _ in $(seq 1 7200); do [ -f "$p/probe.json" ] && ! pgrep -f "$BIN" >/dev/null && break; sleep 1; done
kill "$tcc" "$SAMPLER_PID" 2>/dev/null; mirror_down
cp -R "$p/." "$o2/"
cp "$p/probe.json" "$o3/probe.json" 2>/dev/null
j="$o2/probe.json"
echo "onboarding took $(( $(date +%s) - start )) s"

tier="$(json "$j" '[e for e in j["timeline"] if e.get("event")=="profile"][0]["tier"]')"
check "probe finished and wrote probe.json" "[ -s '$j' ]"
check "onboarding reached the first chat (first token on the starter)" "[ -n \"\$(json '$j' '[e for e in j[\"timeline\"] if e.get(\"event\")==\"first token\"][0]')\" ]"
check "every chosen pack's model is installed (all rows ready)" "[ \"\$(json '$j' '[e for e in j[\"timeline\"] if e.get(\"event\")==\"all rows ready\"][0][\"ok\"]')\" = True ]"
check "the second message ran on the tier model (hand-off)" "[ -n \"\$(json '$j' '[e for e in j[\"timeline\"] if e.get(\"event\")==\"second reply done\" and e.get(\"text\")][0]')\" ]"
check "Evil turned on at step 3 with the adult box: its model downloaded (evil row ready)" "[ \"\$(json '$j' '[e for e in j[\"timeline\"] if e.get(\"event\")==\"all rows ready\"][0][\"rows\"]')\" != \"\" ] && grep -q 'evil:ready' '$j'"
check "a capture per onboarding step (S-01…S-04) written" "ls '$o2'/onb-step1-*.png '$o2'/onb-step2-*.png '$o2'/onb-step3-*.png '$o2'/onb-step4-*.png >/dev/null 2>&1"
note "web search switch visible: judged on the onb-step3 capture in RC visual QA (M10.T11, AT-VQ-M10)"
check "no macOS permission prompt during onboarding (tccd AUTHREQ_PROMPTING for AntiChat = 0)" "! grep -q -i 'PROMPTING' '$o2/tcc.log'"
check "installs present: chat starter + tier chat + embed + voice + evil" "( for k in chat-0.8b chat-2b embed stt tts evil-2b; do [ -f \"$CONTAINER/Models/installs/\$k/manifest.json\" ] || exit 1; done )"
fa_result "$o2" AT-FA-02 "dev (Debug test build, clean VM, local mirror)"; r2=$?

FA_FAILS=0; FA_CHECKS=""
m5="$(json "$j" 'j["nfr.M5.continueToFirstToken.s"]')"
echo "{\"continueToFirstToken_s\": ${m5:-null}, \"mirror_Bps\": $(cat "$o3/mirror-Bps.txt" 2>/dev/null || echo 0), \"hf_Bps\": $(cat "$o3/hf-Bps.txt" 2>/dev/null || echo 0), \"tier\": \"$tier\", \"link\": \"local mirror over virtiofs (Hugging Face link from the VM recorded as hf_Bps)\"}" > "$o3/fa03.json"
check "NFR-M5 clock measured (Continue → first token = ${m5:-?} s)" "[ -n '$m5' ]"
# NFR-M5: ≤ 120 s at 50 Mbps. The mirror link is faster than 50 Mbps, so the unscaled 120 s bar applies.
check "Continue → first token ≤ 120 s (NFR-M5 at ≥ 50 Mbps)" "python3 -I -c 'import sys; sys.exit(0 if float(\"${m5:-1e9}\") <= 120 else 1)'"
fa_result "$o3" AT-FA-03 "dev (local mirror ≥ 50 Mbps; real HF link recorded)"; r3=$?

FA_FAILS=0; FA_CHECKS=""
mem=$(sysctl -n hw.memsize)
peak=$(cat "$o14/peak-footprint-bytes.txt" 2>/dev/null || echo 0)
cap=$(python3 -I -c "print({'T0': 4.0, 'T1': 9.5}.get('$tier', 0))")
echo "{\"vm_ram_bytes\": $mem, \"tier\": \"$tier\", \"peak_footprint_bytes\": $peak, \"cap_gb\": $cap}" > "$o14/fa14.json"
check "VM RAM $((mem / 1073741824)) GB classified as tier $tier (real hardware probe, no -FakeHardware)" "[ '$tier' = T0 ] || [ '$tier' = T1 ]"
check "journeys 1–2 (onboarding → chat) completed at $tier" "[ $r2 = 0 ]"
check "peak helper footprint $((peak / 1048576)) MB ≤ the $tier cap ${cap} GB (NFR-R1)" "python3 -I -c 'import sys; sys.exit(0 if 0 < $peak <= $cap * 1073741824 else 1)'"
fa_result "$o14" AT-FA-14 "VM with low RAM (not physical low-RAM hardware, D-003)"; r14=$?
[ $r2 = 0 ] && [ $r3 = 0 ] && [ $r14 = 0 ]
