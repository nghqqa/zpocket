# ZPocket launcher icon generator (v2, Pillow-rendered wordmark).
#
# Design: full-bleed opaque black square + white "ZP" wordmark set in
# JetBrains Mono Bold (tools/fonts/, SIL OFL 1.1 — license allows
# bundling; keep OFL.txt next to the TTF). Layout is the same envelope
# the guard test app/test/launcher_icon_test.dart pins:
#   - five mipmap sizes (48/72/96/144/192), all pixels alpha=255,
#     corners exact [0,0,0,255]
#   - in the 192px master, white pixels (RGB>220) within y>=130 with
#     bbox width>=90, height>=15, horizontally centered at x=96 (+-2)
#
# Usage: python tools/gen_icon.py   (requires Pillow; run from repo)
# Writes android/app/src/main/res/mipmap-*/ic_launcher.png

import os

from PIL import Image, ImageDraw, ImageFont

GRID = 192          # xxxhdpi master (guard-test reference frame)
SS = 4              # supersample factor
RENDER = GRID * SS  # 768
SIZES = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}

WORD = 'ZP'
FONT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         'fonts', 'JetBrainsMono-Bold.ttf')

# Wordmark envelope on the 192 grid (lower band, see guard test):
# ink bottom line and target ink height.
INK_BOTTOM = 178
INK_HEIGHT = 70


def render_master():
    img = Image.new('RGB', (RENDER, RENDER), (0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Size the font so the Z/P ink height hits INK_HEIGHT grid px.
    probe = ImageFont.truetype(FONT_PATH, 100)
    x0, y0, x1, y1 = draw.textbbox((0, 0), WORD, font=probe)
    probe_ink_h = y1 - y0
    size = int(round(100 * (INK_HEIGHT * SS) / probe_ink_h))
    font = ImageFont.truetype(FONT_PATH, size)

    # Tighter-than-mono logo kerning: draw letters individually and
    # pull the pair together by KERN (em-relative).
    z_w = draw.textbbox((0, 0), WORD[0], font=font)[2]
    p_ink = draw.textbbox((0, 0), WORD[1], font=font)
    kern = int(size * -0.06)
    total = z_w + kern + (p_ink[2] - p_ink[0])

    # Vertical placement from the measured ink bbox of the pair.
    full = draw.textbbox((0, 0), WORD, font=font)
    ink_h = full[3] - full[1]
    top = INK_BOTTOM * SS - ink_h

    x = (RENDER - total) // 2
    draw.text((x, top - full[1]), WORD[0], font=font, fill=(255, 255, 255))
    draw.text((x + z_w + kern - p_ink[0], top - full[1]),
              WORD[1], font=font, fill=(255, 255, 255))
    return img


def write_png(path, img):
    img.save(path, 'PNG')


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.dirname(here)
    base = os.path.join(repo, 'app', 'android', 'app', 'src', 'main', 'res')
    if not os.path.isdir(base):
        base = os.path.join(repo, 'android', 'app', 'src', 'main', 'res')

    master_192 = render_master().resize((GRID, GRID), Image.LANCZOS).convert('RGBA')
    for dpi, size in SIZES.items():
        out = master_192.resize((size, size), Image.LANCZOS)
        write_png(os.path.join(base, 'mipmap-' + dpi, 'ic_launcher.png'), out)
        print('wrote', os.path.join('mipmap-' + dpi, 'ic_launcher.png'), f'({size}x{size})')


if __name__ == '__main__':
    main()
