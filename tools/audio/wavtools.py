"""Shared helpers for tools/audio (M0.T05). Stdlib only: 16/24/32-bit PCM and 32-bit float WAV."""
from __future__ import annotations

import math
import struct
import wave


def read_wav(path: str, channel: int = 0) -> tuple[list[float], int]:
    with open(path, "rb") as f:
        data = f.read()
    assert data[:4] == b"RIFF" and data[8:12] == b"WAVE", f"{path}: not a WAV file"
    i, fmt, ch, rate, bits, pcm = 12, None, 1, 0, 16, b""
    while i + 8 <= len(data):
        cid, size = data[i:i + 4], struct.unpack("<I", data[i + 4:i + 8])[0]
        body = data[i + 8:i + 8 + size]
        if cid == b"fmt ":
            fmt, ch, rate = struct.unpack("<HHI", body[:8])
            bits = struct.unpack("<H", body[14:16])[0]
            if fmt == 0xFFFE:  # WAVE_FORMAT_EXTENSIBLE: subformat GUID's first two bytes
                fmt = struct.unpack("<H", body[24:26])[0]
        elif cid == b"data":
            pcm = body
        i += 8 + size + (size & 1)
    width = bits // 8
    n = len(pcm) // (width * ch)
    out = []
    for k in range(n):
        off = (k * ch + channel) * width
        b = pcm[off:off + width]
        if fmt == 3 and width == 4:
            out.append(struct.unpack("<f", b)[0])
        elif width == 2:
            out.append(struct.unpack("<h", b)[0] / 32768.0)
        elif width == 3:
            v = int.from_bytes(b, "little", signed=True)
            out.append(v / 8388608.0)
        elif width == 4:
            out.append(struct.unpack("<i", b)[0] / 2147483648.0)
    return out, rate


def window_dbfs(x: list[float], rate: int, ms: int = 10) -> list[float]:
    w = max(1, rate * ms // 1000)
    out = []
    for i in range(0, len(x) - w + 1, w):
        s = sum(v * v for v in x[i:i + w]) / w
        out.append(10 * math.log10(s) if s > 0 else -200.0)
    return out


def write_wav16(path: str, x: list[float], rate: int) -> None:
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, v)) * 32767)) for v in x))
