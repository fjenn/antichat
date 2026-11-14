#!/usr/bin/env python3
"""M0.T06 probe: start sd-server with a klein set, run N jobs, record per-step preview observation,
timings and phys_footprint. Usage: sd-probe.py BIN MODELS_DIR q4|q8 RES N PREVIEW [cancel_step] OUTDIR"""
import base64, ctypes, hashlib, json, os, socket, subprocess, sys, time, urllib.request

BIN, MD, Q, RES, N, PREVIEW, CANCEL, OUT = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), sys.argv[6], int(sys.argv[7]), sys.argv[8]
os.makedirs(OUT, exist_ok=True)
lib = ctypes.CDLL("/usr/lib/libproc.dylib")
class RU(ctypes.Structure):
    _fields_ = [("u", ctypes.c_uint8 * 16)] + [(f"f{i}", ctypes.c_uint64) for i in range(40)]
def fp(pid):
    r = RU()
    if lib.proc_pid_rusage(pid, 4, ctypes.byref(r)) != 0: return 0
    return r.f7  # ri_phys_footprint is the 8th uint64
s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
diff = f"{MD}/img-klein/flux-2-klein-4b-{'Q4_0' if Q=='q4' else 'Q8_0'}.gguf"
te = f"{MD}/img-te/Qwen3-4B-{'Q4_K_M' if Q=='q4' else 'Q8_0'}.gguf"
vae = f"{MD}/img-vae-flux2/split_files/vae/flux2-vae.safetensors"
os.makedirs("/tmp/t06-sdmodels", exist_ok=True)
args = [BIN, "--listen-ip", "127.0.0.1", "--listen-port", str(port), "--model-dir", "/tmp/t06-sdmodels",
        "--diffusion-model", diff, "--llm", te, "--vae", vae] + os.environ.get("SD_EXTRA", "").split()
args = [a for a in args if a]
log = open(f"{OUT}/sd-server.log", "w")
t0 = time.time()
p = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT)
def req(method, path, body=None):
    r = urllib.request.Request(f"http://127.0.0.1:{port}{path}", method=method,
                               data=json.dumps(body).encode() if body is not None else None,
                               headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(r, timeout=60) as f:
        return f.status, json.loads(f.read() or b"{}")
while True:
    try:
        _, st = req("GET", "/sdcpp/v1/models/status")
        if st.get("state") == "ready": break
    except Exception: pass
    if p.poll() is not None: print("exited"); sys.exit(1)
    time.sleep(0.05)
load_s = time.time() - t0
print(json.dumps({"load_s": load_s, "fp_after_load": fp(p.pid), "args": args[1:]}))
prompts = json.load(open(os.environ.get("PROMPTS", "build/fixtures-t06/images/prompts-50.json")))["prompts"]
for i in range(N):
    pr = prompts[i % len(prompts)]
    idle = fp(p.pid)
    body = {"prompt": pr["prompt"], "width": RES, "height": RES, "seed": pr["seed"], "batch_count": 1,
            "sample_params": {"sample_method": "euler", "sample_steps": 4, "guidance": {"txt_cfg": 1.0}},
            "preview": PREVIEW, "preview_interval": 1, "output_format": "png", "embed_image_metadata": False}
    ts = time.time()
    code, j = req("POST", "/sdcpp/v1/img_gen", body)
    jid = j["id"]; seen = []; first = None; peak = idle; cancel_at = None; stat = None
    while True:
        _, s = req("GET", f"/sdcpp/v1/jobs/{jid}")
        peak = max(peak, fp(p.pid))
        pv = s.get("preview")
        if pv:
            k = (pv["pass"], pv["step"])
            if not seen or seen[-1][0] != k:
                seen.append((k, time.time() - ts, len(pv["b64_json"])))
                if first is None: first = time.time() - ts
                if CANCEL and pv["step"] >= CANCEL and cancel_at is None:
                    cancel_at = time.time(); req("POST", f"/sdcpp/v1/jobs/{jid}/cancel", {})
        if s["status"] in ("completed", "failed", "cancelled"):
            stat = s; break
        time.sleep(0.015)
    te_ = time.time()
    rec = {"i": i, "status": stat["status"], "final_s": te_ - ts, "first_preview_s": first,
           "steps_seen": [x[0] for x in seen], "step_times": [round(x[1], 3) for x in seen], "idle_fp": idle, "peak_fp": peak,
           "server_elapsed": ((stat.get("completed") or 0) - (stat.get("started") or 0)) / 1000}
    if cancel_at: rec["cancel_to_stop_s"] = te_ - cancel_at
    if stat["status"] == "completed":
        png = base64.b64decode(stat["result"]["images"][0]["b64_json"])
        open(f"{OUT}/probe-{Q}-{RES}-{i}.png", "wb").write(png)
        rec["sha"] = hashlib.sha256(png).hexdigest()[:16]
    elif stat.get("error"): rec["error"] = stat["error"]
    time.sleep(0.5); rec["fp_after"] = fp(p.pid)
    print(json.dumps(rec)); sys.stdout.flush()
p.terminate(); p.wait()
