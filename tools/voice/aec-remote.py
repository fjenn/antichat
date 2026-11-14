#!/usr/bin/env python3
"""M3.T12 AT-280 AC1, second-device variant (A-M3-T12b): the scripted questions play on another device (an iPhone,
iPad or second computer in the same network, or a Bluetooth speaker paired to it), i.e. outside this Mac's echo
reference. `AntiChat -Bench aec --source remote --remote-state <file>` writes {seq, wav, text} to <file> when the next
question is due; this server serves a page that polls it, plays the WAV, and reports the start (<file>.started).
  python3 -I tools/voice/aec-remote.py --state build/at/AT-280/remote-state.json [--port 8765]
Open http://<this Mac's address>:<port>/ on the other device and tap "Start". Local network only; stdlib only.
"""
import argparse
import http.server
import json
import os
import socket

PAGE = """<!doctype html><meta name=viewport content="width=device-width,initial-scale=1">
<title>AntiChat AEC questions</title><body style="font:20px -apple-system;margin:24px">
<button id=b style="font-size:28px;padding:16px 28px">Start</button>
<p id=s>Tap Start, put this device about 1 m from the Mac, volume about 70 %.</p>
<audio id=a></audio><script>
let seq=0, armed=false; const a=document.getElementById('a'), s=document.getElementById('s');
document.getElementById('b').onclick=()=>{armed=true; a.src='/silence'; a.play().catch(()=>{}); s.textContent='Waiting for the first question…';};
async function poll(){ try{ const r=await fetch('/state',{cache:'no-store'}); const j=await r.json();
  if(armed && j.seq && j.seq!==seq){ seq=j.seq; s.textContent='Question '+seq+': '+(j.text||'');
    a.src='/audio?seq='+seq; a.onplaying=()=>fetch('/started?seq='+seq); await a.play(); } }catch(e){}
  setTimeout(poll,200);} poll();
</script>"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--state", required=True)
    ap.add_argument("--port", type=int, default=8765)
    a = ap.parse_args()
    state = os.path.abspath(a.state)
    for f in (state, state + ".started"):
        if os.path.exists(f):
            os.remove(f)

    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def send(self, code, ctype, body):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path, _, query = self.path.partition("?")
            cur = {}
            if os.path.exists(state):
                try:
                    cur = json.load(open(state))
                except ValueError:
                    cur = {}
            if path == "/":
                return self.send(200, "text/html; charset=utf-8", PAGE.encode())
            if path == "/state":
                return self.send(200, "application/json", json.dumps({"seq": cur.get("seq", 0), "text": cur.get("text", "")}).encode())
            if path == "/audio" and cur.get("wav"):
                return self.send(200, "audio/wav", open(cur["wav"], "rb").read())
            if path == "/silence":
                import struct
                n = 1600
                hdr = b"RIFF" + struct.pack("<I", 36 + 2 * n) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, 16000, 32000, 2, 16) + b"data" + struct.pack("<I", 2 * n)
                return self.send(200, "audio/wav", hdr + b"\0" * (2 * n))
            if path == "/started":
                seq = query.partition("=")[2]
                with open(state + ".started.tmp", "w") as f:
                    f.write(seq)
                os.replace(state + ".started.tmp", state + ".started")
                return self.send(200, "text/plain", b"ok")
            return self.send(404, "text/plain", b"not found")

    host = socket.gethostbyname(socket.gethostname())
    print(f"open http://{host}:{a.port}/ on the second device (or http://<Mac name>.local:{a.port}/)", flush=True)
    http.server.ThreadingHTTPServer(("0.0.0.0", a.port), H).serve_forever()


if __name__ == "__main__":
    main()
