#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 F4 contributors

"""Renders the F4 brandmark to a transparent PNG.

The mark is six rectangles, so it is drawn here directly rather than rasterised
from the SVG. Every SVG rasteriser reachable without Xcode (qlmanage) composites
onto an opaque white background, which is exactly what an app icon must not
have. Writing the pixels means the alpha channel is whatever we say it is.

Geometry is kept in the SVG's 512x512 coordinate space and scaled on output, so
this file and f4-brandmark.svg stay in step.

    python3 Tools/make_brandmark.py <out.png> [size] [--white]
"""

import struct
import sys
import zlib

VIEWBOX = 512

# (x, y, w, h) in the 512x512 viewBox, matching f4-brandmark.svg.
BARS = [
    # F
    (80, 128, 56, 256),
    (80, 128, 160, 56),
    (80, 228, 132, 56),
    # 4
    (272, 128, 56, 156),
    (272, 228, 160, 56),
    (376, 128, 56, 256),
]


def render(size: int, rgb: tuple[int, int, int]) -> bytes:
    """An RGBA buffer: the bars in `rgb`, everything else fully transparent."""
    scale = size / VIEWBOX
    row_bytes = size * 4
    # Fully transparent, and transparent *black* rather than transparent white:
    # premultiplied compositors bleed the colour of zero-alpha pixels into the
    # edges, which shows up as a pale halo when the icon is downscaled.
    buf = bytearray(row_bytes * size)

    r, g, b = rgb
    for bx, by, bw, bh in BARS:
        x0, x1 = round(bx * scale), round((bx + bw) * scale)
        y0, y1 = round(by * scale), round((by + bh) * scale)
        for y in range(max(0, y0), min(size, y1)):
            base = y * row_bytes
            for x in range(max(0, x0), min(size, x1)):
                o = base + x * 4
                buf[o : o + 4] = bytes((r, g, b, 255))
    return bytes(buf)


def encode_png(pixels: bytes, size: int) -> bytes:
    row_bytes = size * 4
    # Filter type 0 (None) on every scanline; the image is flat colour, so the
    # filters that help photographs would only cost time here.
    raw = b"".join(
        b"\x00" + pixels[y * row_bytes : (y + 1) * row_bytes] for y in range(size)
    )

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    return b"".join(
        [
            b"\x89PNG\r\n\x1a\n",
            # 8-bit, colour type 6 (RGBA), no interlace.
            chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)),
            chunk(b"IDAT", zlib.compress(raw, 9)),
            chunk(b"IEND", b""),
        ]
    )


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        print(__doc__.strip().splitlines()[-1].strip(), file=sys.stderr)
        return 2

    out = args[0]
    size = int(args[1]) if len(args) > 1 else 1024
    rgb = (255, 255, 255) if "--white" in sys.argv[1:] else (0, 0, 0)

    with open(out, "wb") as fh:
        fh.write(encode_png(render(size, rgb), size))
    print(f"wrote {out} ({size}x{size}, transparent)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
