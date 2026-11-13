# ZPocket launcher icon generator (v4 — full-bleed ZP monogram).
#
# Design: same language as the ZCode desktop icon — pure black tile,
# one oversized white glyph, no effects. Our glyph is the ZP pair set
# tight (-0.10em pair kern) so it reads as a single monogram block;
# full-bleed opaque black keeps every launcher-mask variant safe.
#
# Font: JetBrains Mono Bold (tools/fonts/, SIL OFL 1.1 — license
# bundled in tools/fonts/OFL.txt).
#
# Guard envelope (app/test/launcher_icon_test.dart, rewritten for v4):
#   - five mipmap sizes, all pixels alpha=255, corners exact [0,0,0,255]
#   - 192px master: white-pixel bbox width>=110, height>=90,
#     centered at x=96 (+-2), optical vertical center 94 (+-4)
#
# Usage: python tools/gen_icon.py   (requires Pillow)
# Writes android/app/src/main/res/mipmap-*/ic_launcher.png

import os

from PIL import Image, ImageDraw, ImageFont

GRID = 192
SS = 4
RENDER = GRID * SS
SIZES = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}

WORD = 'ZP'
FONT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         'fonts', 'JetBrainsMono-Bold.ttf')

INK_HEIGHT = 102        # wordmark ink height on the 192 grid
INK_CY = 94             # optical vertical center (slightly above middle)
KERN = -0.10            # em-relative pair kern: near-touching monogram


def render_master():
    img = Image.new('RGB', (RENDER, RENDER), (0, 0, 0))
    draw = ImageDraw.Draw(img)

    # size the font so the wordmark ink height hits INK_HEIGHT
    probe = ImageFont.truetype(FONT_PATH, 100)
    _, y0, _, y1 = draw.textbbox((0, 0), WORD, font=probe)
    size = int(round(100 * (INK_HEIGHT * SS) / (y1 - y0)))
    font = ImageFont.truetype(FONT_PATH, size)

    # measure per-letter ink and lay the pair out with custom kerning
    z_bb = draw.textbbox((0, 0), WORD[0], font=font)
    p_bb = draw.textbbox((0, 0), WORD[1], font=font)
    gap = int(size * KERN)
    total = (z_bb[2] - z_bb[0]) + gap + (p_bb[2] - p_bb[0])
    left = (RENDER - total) // 2
    top = INK_CY * SS - INK_HEIGHT * SS // 2

    x = left
    for ch, bb in ((WORD[0], z_bb), (WORD[1], p_bb)):
        draw.text((x - bb[0], top - draw.textbbox((0, 0), ch, font=font)[1]),
                  ch, font=font, fill=(255, 255, 255))
        x += (bb[2] - bb[0]) + gap

    # deterministic re-center: measure white ink and shift to canvas
    # center (AA/threshold asymmetry otherwise costs 1-3 px)
    bbox = img.convert('L').point(lambda v: 255 if v > 220 else 0).getbbox()
    if bbox:
        dx = int(round(RENDER / 2 - (bbox[0] + bbox[2]) / 2))
        if dx:
            img = img.transform(
                (RENDER, RENDER), Image.AFFINE, (1, 0, -dx, 0, 1, 0),
                resample=Image.NEAREST, fillcolor=(0, 0, 0),
            )
    return img


def self_check(master_192):
    gray = master_192.convert('L')
    bbox = gray.point(lambda v: 255 if v > 220 else 0).getbbox()
    if not bbox:
        print('self-check: FAIL (no white pixels)')
        return False
    w, h = bbox[2] - bbox[0], bbox[3] - bbox[1]
    cx, cy = (bbox[0] + bbox[2]) / 2, (bbox[1] + bbox[3]) / 2
    ok = w >= 110 and h >= 90 and abs(cx - 96) <= 2 and abs(cy - 94) <= 4
    print(f'self-check: bbox w={w} h={h} cx={cx:.1f} cy={cy:.1f} -> '
          + ('OK' if ok else 'FAIL'))
    return ok


def main():
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    base = os.path.join(repo, 'app', 'android', 'app', 'src', 'main', 'res')
    if not os.path.isdir(base):
        base = os.path.join(repo, 'android', 'app', 'src', 'main', 'res')

    master = render_master().resize((GRID, GRID), Image.LANCZOS).convert('RGBA')
    if not self_check(master):
        raise SystemExit('self-check failed; icons NOT written')
    for dpi, size in SIZES.items():
        out = master.resize((size, size), Image.LANCZOS)
        out.save(os.path.join(base, 'mipmap-' + dpi, 'ic_launcher.png'), 'PNG')
        print('wrote', f'mipmap-{dpi}/ic_launcher.png ({size}x{size})')


if __name__ == '__main__':
    main()
