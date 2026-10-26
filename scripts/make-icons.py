"""Generate the Roku channel icons (dark background, blue play triangle). Stdlib only."""
import struct
import zlib
from pathlib import Path

BG, FG = (10, 10, 10), (96, 165, 250)


def icon(w: int, h: int) -> bytes:
    cx, cy, r = w / 2, h / 2, min(w, h) * 0.28
    rows = []
    for y in range(h):
        row = bytearray([0])  # PNG filter type 0
        for x in range(w):
            # Right-pointing triangle centred on (cx, cy).
            dx, dy = x - (cx - r * 0.6), abs(y - cy)
            inside = 0 <= dx <= r * 1.5 and dy <= r * (1 - dx / (r * 1.5))
            row += bytes(FG if inside else BG)
        rows.append(bytes(row))

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"".join(rows), 9))
            + chunk(b"IEND", b""))


out = Path(__file__).resolve().parent.parent / "roku" / "images"
out.mkdir(exist_ok=True)
(out / "icon_hd.png").write_bytes(icon(290, 218))
(out / "icon_sd.png").write_bytes(icon(246, 140))
print("wrote", *sorted(p.name for p in out.glob("*.png")))
