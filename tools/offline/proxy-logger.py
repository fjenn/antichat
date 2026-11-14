#!/usr/bin/env python3
"""M2.T03 step 7 (AT-209 AC2, R-297 AC2): a mitm-free HTTP/CONNECT logging proxy on 127.0.0.1:8899. Logs one line
per request (`<ts> CONNECT host:port` or `<ts> GET http://…`) to --log and relays bytes unchanged. `--rate <mbit>`
adds a token-bucket throttle (the non-sudo NFR-M5 path, labelled `throttle: userspace`). Run with `python3 -I`.
The app is pointed at it with the DEBUG launch argument `-TestProxy 127.0.0.1:8899` (NetworkGate.testProxy).
"""
import argparse, asyncio, time


class Bucket:
    def __init__(self, mbit):
        self.rate = mbit * 1e6 / 8 if mbit else None
        self.tokens, self.t = 0.0, time.monotonic()

    async def take(self, n):
        if not self.rate:
            return
        while True:
            now = time.monotonic()
            self.tokens = min(self.rate, self.tokens + (now - self.t) * self.rate)
            self.t = now
            if self.tokens >= n:
                self.tokens -= n
                return
            await asyncio.sleep((n - self.tokens) / self.rate)


async def pipe(r, w, bucket):
    try:
        while data := await r.read(65536):
            await bucket.take(len(data))
            w.write(data)
            await w.drain()
    except (ConnectionError, asyncio.IncompleteReadError):
        pass
    finally:
        w.close()


async def handle(cr, cw, log, bucket):
    head = await cr.readuntil(b"\r\n\r\n")
    line = head.split(b"\r\n", 1)[0].decode("latin1")
    method, target, _ = line.split(" ", 2)
    with open(log, "a") as f:
        f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {method} {target}\n")
    if method == "CONNECT":
        host, port = target.rsplit(":", 1)
        ur, uw = await asyncio.open_connection(host, int(port))
        cw.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
        await cw.drain()
    else:
        rest = target.split("://", 1)[1]
        hostport, _, path = rest.partition("/")
        host, _, port = hostport.partition(":")
        ur, uw = await asyncio.open_connection(host, int(port or 80))
        uw.write(head.replace(target.encode(), b"/" + path.encode(), 1))
    await asyncio.gather(pipe(cr, uw, bucket), pipe(ur, cw, bucket))


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8899)
    ap.add_argument("--log", default="build/at/AT-209/proxy.log")
    ap.add_argument("--rate", type=float, default=0, help="Mbit/s token bucket (0 = unthrottled)")
    a = ap.parse_args()
    bucket = Bucket(a.rate)
    server = await asyncio.start_server(lambda r, w: handle(r, w, a.log, bucket), "127.0.0.1", a.port)
    print(f"proxy-logger on 127.0.0.1:{a.port}" + (f" throttle: userspace {a.rate} Mbit/s" if a.rate else ""), flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
