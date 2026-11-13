# ZPocket launcher icon generator (reproducible, no external deps).
#
# Design: full-bleed opaque black square + white "ZP" monogram in the
# lower band. Matches the guard test app/test/launcher_icon_test.dart:
#   - five mipmap sizes (48/72/96/144/192), all pixels alpha=255,
#     corners exact [0,0,0,255]
#   - in the 192px master, white pixels (RGB>220) within y>=130 with
#     bbox width>=90, height>=15, horizontally centered at x=96 (+-2)
#
# Usage: python tools/gen_icon.py   (run from repo root or app/)
# Writes android/app/src/main/res/mipmap-*/ic_launcher.png

import os
import struct
import zlib

SS = 4                      # supersample factor (render 4x, box-downsample)
MASTER = 192                # xxxhdpi master size
R = MASTER * SS             # render size (768)

def draw_zp_mark(px, size):
    """Draw the white ZP monogram scaled to `size` (coordinates defined on 192)."""
    s = size / 192.0

    def rect(x0, y0, x1, y1):
        for y in range(int(y0 * s), int(y1 * s)):
            row = y * size
            for x in range(int(x0 * s), int(x1 * s)):
                px[row + x] = 255

    sw = 13  # stroke width on the 192 grid

    # --- Z glyph: x 40..86 ---
    z_x0, z_x1 = 40, 86
    rect(z_x0, 118, z_x1, 118 + sw)            # top bar
    rect(z_x0, 178 - sw, z_x1, 178)            # bottom bar
    # diagonal: top-right -> bottom-left, drawn at supersampled row
    # resolution so every hi-res row gets a full white run (crisp after
    # box-downsample; per-192-grid-row spans would alias to gray)
    y0_hi = int((118 + sw) * s)
    y1_hi = int((178 - sw) * s)
    for ys in range(y0_hi, y1_hi):
        t = (ys - y0_hi) / float(y1_hi - y0_hi - 1)
        cx = ((z_x1 - 2) * (1 - t) + (z_x0 + 2) * t) * s
        # clamp to the Z glyph bounds so the bbox (guarded by the icon
        # test) stays 40..152 -> centered at x=96
        x0 = max(int(cx - sw * 0.62 * s), int(z_x0 * s))
        x1 = min(int(cx + sw * 0.38 * s), int(z_x1 * s))
        row = ys * size
        for x in range(max(0, x0), min(size, x1)):
            px[row + x] = 255

    # --- P glyph: x 106..152 ---
    p_x0, p_x1 = 106, 152
    rect(p_x0, 118, p_x0 + sw, 178)            # stem
    rect(p_x0, 118, p_x1, 118 + sw)            # bowl top
    rect(p_x1 - sw, 118, p_x1, 152)            # bowl right
    rect(p_x0, 152 - sw, p_x1, 152)            # bowl bottom


def write_png(path, w, h, rgba):
    def chunk(tag, data):
        c = struct.pack('>I', len(data)) + tag + data
        return c + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF)

    raw = b''.join(
        b'\x00' + bytes(rgba[y * w * 4:(y + 1) * w * 4]) for y in range(h)
    )
    png = (b'\x89PNG\r\n\x1a\n'
           + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
           + chunk(b'IDAT', zlib.compress(raw, 9))
           + chunk(b'IEND', b''))
    with open(path, 'wb') as f:
        f.write(png)


def render(size):
    """Render the icon at `size` px (opaque black bg + white mark)."""
    hi = size * SS
    px = bytearray(hi * hi)          # white-mask (0=black, 255=white)
    draw_zp_mark(px, hi)
    # box-downsample with alpha-lerp onto black bg -> RGB
    inv = SS * SS
    out = bytearray(size * size * 4)
    for y in range(size):
        for x in range(size):
            acc = 0
            for dy in range(SS):
                row = (y * SS + dy) * hi
                for dx in range(SS):
                    acc += px[row + x * SS + dx]
            v = acc // inv
            o = (y * size + x) * 4
            out[o] = v
            out[o + 1] = v
            out[o + 2] = v
            out[o + 3] = 255
    return out


SIZES = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}

def main():
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.dirname(here)
    base = os.path.join(repo, 'app', 'android', 'app', 'src', 'main', 'res')
    if not os.path.isdir(base):
        base = os.path.join(repo, 'android', 'app', 'src', 'main', 'res')
    for dpi, size in SIZES.items():
        data = render(size)
        path = os.path.join(base, 'mipmap-' + dpi, 'ic_launcher.png')
        write_png(path, size, size, data)
        print('wrote', path, f'({size}x{size})')

if __name__ == '__main__':
    main()
