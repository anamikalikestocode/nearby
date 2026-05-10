#!/usr/bin/env python3
"""Generate a DMG background image with a drag arrow from app to Applications."""
import math
import struct
import zlib
import os

WIDTH = 540
HEIGHT = 380

def make_png(width, height, pixels):
    def chunk(chunk_type, data):
        c = chunk_type + data
        crc = struct.pack('>I', zlib.crc32(c) & 0xffffffff)
        return struct.pack('>I', len(data)) + c + crc
    header = b'\x89PNG\r\n\x1a\n'
    ihdr = chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
    raw = b''
    for y in range(height):
        raw += b'\x00'
        for x in range(width):
            idx = (y * width + x) * 4
            raw += bytes(pixels[idx:idx+4])
    idat = chunk(b'IDAT', zlib.compress(raw, 9))
    iend = chunk(b'IEND', b'')
    return header + ihdr + idat + iend

def lerp(a, b, t):
    return a + (b - a) * t

def generate_bg():
    W, H = WIDTH, HEIGHT
    pixels = [0] * (W * H * 4)

    for y in range(H):
        for x in range(W):
            idx = (y * W + x) * 4
            # Soft gradient: light gray top to slightly darker bottom
            t = y / H
            v = int(lerp(248, 235, t))
            pixels[idx] = v
            pixels[idx+1] = v
            pixels[idx+2] = v
            pixels[idx+3] = 255

    # Draw a curved arrow from left (app position ~130,150) to right (Applications ~410,150)
    # Arrow body: dashed line at y=220 from x=180 to x=360
    arrow_y = 230
    arrow_x_start = 180
    arrow_x_end = 360
    arrow_color = (120, 120, 120)

    for y in range(H):
        for x in range(W):
            idx = (y * W + x) * 4

            # Arrow shaft — dashed
            if arrow_x_start <= x <= arrow_x_end:
                dy = abs(y - arrow_y)
                if dy < 2.5:
                    # Dashes: 12px on, 8px off
                    dash_pos = (x - arrow_x_start) % 20
                    if dash_pos < 12:
                        a = (1.0 - dy / 2.5) * 0.6
                        r0, g0, b0 = pixels[idx], pixels[idx+1], pixels[idx+2]
                        pixels[idx] = int(lerp(r0, arrow_color[0], a))
                        pixels[idx+1] = int(lerp(g0, arrow_color[1], a))
                        pixels[idx+2] = int(lerp(b0, arrow_color[2], a))

            # Arrowhead pointing right at (arrow_x_end, arrow_y)
            tip_x = arrow_x_end + 8
            if tip_x - 25 <= x <= tip_x:
                progress = (tip_x - x) / 25.0  # 0 at tip, 1 at base
                half_h = progress * 12  # widens toward base
                dy = abs(y - arrow_y)
                if dy <= half_h + 1:
                    a = max(0, min(1, (half_h + 1 - dy) / 2.0)) * 0.7
                    r0, g0, b0 = pixels[idx], pixels[idx+1], pixels[idx+2]
                    pixels[idx] = int(lerp(r0, arrow_color[0], a))
                    pixels[idx+1] = int(lerp(g0, arrow_color[1], a))
                    pixels[idx+2] = int(lerp(b0, arrow_color[2], a))

    return pixels

def main():
    base = os.path.dirname(os.path.abspath(__file__))
    print("Generating DMG background...")
    pixels = generate_bg()
    png_data = make_png(WIDTH, HEIGHT, pixels)
    out = os.path.join(base, "dmg_background.png")
    with open(out, 'wb') as f:
        f.write(png_data)
    print(f"  Saved {out}")

if __name__ == "__main__":
    main()
