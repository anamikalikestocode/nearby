#!/usr/bin/env python3
"""Generate the Nearby app icon: Find My-style grid with a red location pin."""
import math
import struct
import zlib
import os
import subprocess

SIZE = 1024
CORNER_RADIUS = 220  # macOS icon rounded corners

def make_png(width, height, pixels):
    """Create a PNG file from raw RGBA pixel data."""
    def chunk(chunk_type, data):
        c = chunk_type + data
        crc = struct.pack('>I', zlib.crc32(c) & 0xffffffff)
        return struct.pack('>I', len(data)) + c + crc

    header = b'\x89PNG\r\n\x1a\n'
    ihdr = chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))

    raw = b''
    for y in range(height):
        raw += b'\x00'  # filter none
        for x in range(width):
            idx = (y * width + x) * 4
            raw += bytes(pixels[idx:idx+4])

    idat = chunk(b'IDAT', zlib.compress(raw, 9))
    iend = chunk(b'IEND', b'')
    return header + ihdr + idat + iend


def lerp(a, b, t):
    return a + (b - a) * t


def blend(bg, fg):
    """Alpha-composite fg over bg. Both are (r,g,b,a) 0-255."""
    fa = fg[3] / 255.0
    ba = bg[3] / 255.0
    oa = fa + ba * (1 - fa)
    if oa == 0:
        return (0, 0, 0, 0)
    r = int((fg[0] * fa + bg[0] * ba * (1 - fa)) / oa)
    g = int((fg[1] * fa + bg[1] * ba * (1 - fa)) / oa)
    b = int((fg[2] * fa + bg[2] * ba * (1 - fa)) / oa)
    return (r, g, b, int(oa * 255))


def in_rounded_rect(x, y, w, h, r):
    """Check if (x,y) is inside a rounded rectangle of size w×h with corner radius r."""
    if r <= 0:
        return True
    # Check corners
    corners = [(r, r), (w - r, r), (r, h - r), (w - r, h - r)]
    for cx, cy in corners:
        dx = abs(x - cx)
        dy = abs(y - cy)
        if x < r or x > w - r:
            if y < r or y > h - r:
                if dx * dx + dy * dy > r * r:
                    return False
    if x < 0 or x >= w or y < 0 or y >= h:
        return False
    return True


def smoothstep(edge0, edge1, x):
    t = max(0.0, min(1.0, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)


def generate_icon():
    S = SIZE
    pixels = [0] * (S * S * 4)

    # Colors - dark navy/teal gradient like Find My
    bg_top = (15, 25, 50)       # deep navy
    bg_bot = (10, 45, 65)       # dark teal
    grid_color = (40, 90, 130)  # blue-gray grid lines
    grid_bright = (50, 120, 170)  # brighter grid lines for major ones

    # Pin colors
    pin_red = (235, 60, 55)
    pin_dark = (190, 35, 30)
    pin_highlight = (255, 120, 110)
    pin_white = (255, 255, 255)

    cx, cy = S // 2, S // 2  # center

    for y in range(S):
        for x in range(S):
            idx = (y * S + x) * 4

            # Rounded rect mask
            if not in_rounded_rect(x, y, S, S, CORNER_RADIUS):
                pixels[idx] = 0
                pixels[idx+1] = 0
                pixels[idx+2] = 0
                pixels[idx+3] = 0
                continue

            # Distance from edge for anti-aliasing the rounded corners
            aa = 1.0
            corners = [(CORNER_RADIUS, CORNER_RADIUS),
                       (S - CORNER_RADIUS, CORNER_RADIUS),
                       (CORNER_RADIUS, S - CORNER_RADIUS),
                       (S - CORNER_RADIUS, S - CORNER_RADIUS)]
            for ccx, ccy in corners:
                dx = abs(x - ccx)
                dy = abs(y - ccy)
                if (x < CORNER_RADIUS or x > S - CORNER_RADIUS) and \
                   (y < CORNER_RADIUS or y > S - CORNER_RADIUS):
                    dist = math.sqrt(dx*dx + dy*dy)
                    if dist > CORNER_RADIUS - 1.5:
                        aa = max(0.0, min(1.0, CORNER_RADIUS + 0.5 - dist))

            # Background gradient
            t = y / S
            r = int(lerp(bg_top[0], bg_bot[0], t))
            g = int(lerp(bg_top[1], bg_bot[1], t))
            b = int(lerp(bg_top[2], bg_bot[2], t))

            # Subtle radial glow from center (like Find My's radar look)
            dist_from_center = math.sqrt((x - cx)**2 + (y - cy)**2)
            glow = max(0, 1.0 - dist_from_center / (S * 0.55))
            glow = glow * glow * 0.25  # subtle
            r = min(255, int(r + glow * 40))
            g = min(255, int(g + glow * 80))
            b = min(255, int(b + glow * 100))

            # ── Grid lines (Find My style — PROMINENT) ──
            # Major grid: every 128px. Minor grid: every 64px.
            # Lines span the ENTIRE icon, edge to edge.
            grid_alpha = 0.0

            # Minor grid lines
            minor_spacing = 64
            for gx in range(0, S + 1, minor_spacing):
                d = abs(x - gx)
                if d < 2.2:
                    line_a = (1.0 - d / 2.2) * 0.30
                    grid_alpha = max(grid_alpha, line_a)
            for gy in range(0, S + 1, minor_spacing):
                d = abs(y - gy)
                if d < 2.2:
                    line_a = (1.0 - d / 2.2) * 0.30
                    grid_alpha = max(grid_alpha, line_a)

            # Major grid lines (thicker, much brighter)
            major_spacing = 128
            for gx in range(0, S + 1, major_spacing):
                d = abs(x - gx)
                if d < 3.5:
                    line_a = (1.0 - d / 3.5) * 0.60
                    grid_alpha = max(grid_alpha, line_a)
            for gy in range(0, S + 1, major_spacing):
                d = abs(y - gy)
                if d < 3.5:
                    line_a = (1.0 - d / 3.5) * 0.60
                    grid_alpha = max(grid_alpha, line_a)

            # Cross-hairs at center (very prominent)
            ch_d_x = abs(x - cx)
            ch_d_y = abs(y - cy)
            if ch_d_x < 3.5:
                ch_a = (1.0 - ch_d_x / 3.5) * 0.65
                grid_alpha = max(grid_alpha, ch_a)
            if ch_d_y < 3.5:
                ch_a = (1.0 - ch_d_y / 3.5) * 0.65
                grid_alpha = max(grid_alpha, ch_a)

            # Apply grid
            if grid_alpha > 0:
                gc = grid_bright if grid_alpha > 0.3 else grid_color
                r = int(lerp(r, gc[0], grid_alpha))
                g = int(lerp(g, gc[1], grid_alpha))
                b = int(lerp(b, gc[2], grid_alpha))

            # ── Concentric radar circles (Find My style — prominent) ──
            for radius in [140, 280, 420]:
                ring_d = abs(dist_from_center - radius)
                if ring_d < 3.0:
                    ring_a = (1.0 - ring_d / 3.0) * 0.35
                    r = int(lerp(r, grid_bright[0], ring_a))
                    g = int(lerp(g, grid_bright[1], ring_a))
                    b = int(lerp(b, grid_bright[2], ring_a))

            # ── Red location pin ──
            # Pin position: slightly above center
            pin_cx = cx
            pin_cy = cy - 60  # pin tip at center-ish, body above

            # Pin body: teardrop shape
            # Upper circle (head of pin)
            head_cx = pin_cx
            head_cy = pin_cy - 100
            head_r = 130

            # Distance from pin head center
            dx_pin = x - head_cx
            dy_pin = y - head_cy
            dist_head = math.sqrt(dx_pin**2 + dy_pin**2)

            # Teardrop: circle on top, pointed bottom
            # The point is at pin_cy + 80
            point_y = pin_cy + 55
            in_pin = False
            pin_alpha = 0.0

            if dist_head <= head_r + 1:
                # In the circular head
                in_pin = True
                pin_alpha = smoothstep(head_r + 1, head_r - 1, dist_head)
            elif y > head_cy and y <= point_y + 1:
                # In the tapered part below the circle
                progress = (y - head_cy) / (point_y - head_cy)
                # Width narrows from circle edge to point
                half_width = head_r * (1 - progress * progress)  # quadratic taper
                if half_width > 0:
                    d_from_axis = abs(x - pin_cx)
                    if d_from_axis <= half_width + 1:
                        in_pin = True
                        pin_alpha = smoothstep(half_width + 1, half_width - 1, d_from_axis)
                        # Also fade at the very tip
                        if progress > 0.9:
                            pin_alpha *= smoothstep(1.0, 0.9, progress)

            if in_pin and pin_alpha > 0:
                # Pin shading: gradient from light (top-left) to dark (bottom-right)
                shade_t = max(0, min(1, (dx_pin + dy_pin) / (head_r * 2) + 0.5))

                pr = int(lerp(pin_highlight[0], pin_dark[0], shade_t))
                pg = int(lerp(pin_highlight[1], pin_dark[1], shade_t))
                pb = int(lerp(pin_highlight[2], pin_dark[2], shade_t))

                # Main red body
                pr = int(lerp(pr, pin_red[0], 0.5))
                pg = int(lerp(pg, pin_red[1], 0.5))
                pb = int(lerp(pb, pin_red[2], 0.5))

                # White inner circle (the hole in the pin)
                inner_r = 48
                if dist_head <= inner_r + 1.5:
                    inner_a = smoothstep(inner_r + 1.5, inner_r - 1.5, dist_head)
                    pr = int(lerp(pr, pin_white[0], inner_a))
                    pg = int(lerp(pg, pin_white[1], inner_a))
                    pb = int(lerp(pb, pin_white[2], inner_a))

                r = int(lerp(r, pr, pin_alpha))
                g = int(lerp(g, pg, pin_alpha))
                b = int(lerp(b, pb, pin_alpha))

            # ── Drop shadow under pin ──
            shadow_cx = pin_cx + 8
            shadow_cy = point_y + 30
            shadow_rx = 70
            shadow_ry = 18
            sdx = (x - shadow_cx) / shadow_rx
            sdy = (y - shadow_cy) / shadow_ry
            shadow_d = sdx * sdx + sdy * sdy
            if shadow_d < 1.0 and not in_pin:
                shadow_a = (1.0 - shadow_d) * 0.3
                r = int(r * (1 - shadow_a))
                g = int(g * (1 - shadow_a))
                b = int(b * (1 - shadow_a))

            # Final pixel
            a_final = int(aa * 255)
            pixels[idx] = max(0, min(255, r))
            pixels[idx+1] = max(0, min(255, g))
            pixels[idx+2] = max(0, min(255, b))
            pixels[idx+3] = a_final

    return pixels


def main():
    base = os.path.dirname(os.path.abspath(__file__))
    print("Generating 1024x1024 icon...")
    pixels = generate_icon()
    png_path = os.path.join(base, "AppIcon_1024.png")
    png_data = make_png(SIZE, SIZE, pixels)
    with open(png_path, 'wb') as f:
        f.write(png_data)
    print(f"  Saved {png_path}")

    # Create iconset and convert to icns
    iconset = os.path.join(base, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)

    sizes = [16, 32, 64, 128, 256, 512, 1024]
    for s in sizes:
        out = os.path.join(iconset, f"icon_{s}x{s}.png")
        subprocess.run(["sips", "-z", str(s), str(s), png_path, "--out", out],
                       capture_output=True)
        if s <= 512:
            out2x = os.path.join(iconset, f"icon_{s//1 if s == 1024 else s}x{s//1 if s == 1024 else s}@2x.png")
            # For @2x: 32@2x = 64px, 128@2x = 256px, etc.

    # Proper iconset naming
    icon_specs = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png"),
    ]

    # Clean and regenerate
    import shutil
    shutil.rmtree(iconset, ignore_errors=True)
    os.makedirs(iconset)

    for px_size, name in icon_specs:
        out = os.path.join(iconset, name)
        subprocess.run(["sips", "-z", str(px_size), str(px_size), png_path, "--out", out],
                       capture_output=True)
        print(f"  {name} ({px_size}px)")

    # Convert to icns
    icns_path = os.path.join(base, "Nearby.app", "Contents", "Resources", "AppIcon.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns_path], check=True)
    print(f"  Created {icns_path}")

    # Cleanup
    shutil.rmtree(iconset)
    print("Done!")


if __name__ == "__main__":
    main()
