# ZPocket launcher icon generator (v3 — "terminal glow" design).
#
# Design language (dev-tool aesthetic):
#   - pure black base with a centered brand-blue radial glow (#134CFF,
#     the app's brandAccent) that decays to EXACT black well before the
#     corners — guards the [0,0,0,255] corner assertion on every size
#   - "ZP" wordmark in JetBrains Mono Bold (OFL 1.1, bundled in
#     tools/fonts/) with a 12% forward slant (speed/motion) and a faint
#     blue under-echo for depth
#   - a brand-blue caret bar under the P — the editor "active cell"
#     cue; blue does not disturb the white bounding box the guard test
#     measures
#   - automatic re-centering of the white wordmark inside the measured
#     band, so the guard test's x-center assertion holds by construction
#
# Guard envelope (app/test/launcher_icon_test.dart):
#   - five mipmap sizes, all pixels alpha=255, corners exact [0,0,0,255]
#   - 192px master: white pixels (RGB>220) within y>=130, bbox
#     width>=90, height>=15, centered at x=96 (+-2)
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

BRAND_BLUE = (0x13, 0x4C, 0xFF)   # theme brandAccent
ECHO_BLUE = (7, 18, 74)           # dark under-echo of the wordmark

INK_BOTTOM = 174                  # wordmark ink bottom line (192 grid)
INK_HEIGHT = 70
SLANT = 0.12                      # forward shear (dx/dy)
CARET_TOP = 179                   # caret bar under the P (192 grid)
CARET_BOTTOM = 186
BAND_TOP = 130                    # guard-test measured band start

HERE = os.path.dirname(os.path.abspath(__file__))


def text_layer(size_px):
    """White wordmark with measured metrics, drawn on transparency."""
    layer = Image.new('RGBA', (size_px, size_px), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    probe = ImageFont.truetype(FONT_PATH, 100)
    x0, y0, x1, y1 = draw.textbbox((0, 0), WORD, font=probe)
    size = int(round(100 * (INK_HEIGHT * SS) / (y1 - y0)))
    font = ImageFont.truetype(FONT_PATH, size)

    z_w = draw.textbbox((0, 0), WORD[0], font=font)[2]
    p_bb = draw.textbbox((0, 0), WORD[1], font=font)
    kern = int(size * -0.06)
    total = z_w + kern + (p_bb[2] - p_bb[0])
    full = draw.textbbox((0, 0), WORD, font=font)
    top = INK_BOTTOM * SS - (full[3] - full[1])
    left = (size_px - total) // 2 - full[0]

    draw.text((left, top - full[1]), WORD, font=font, fill=(255, 255, 255, 255))
    ink = draw.textbbox((left, top - full[1]), WORD, font=font)
    return layer, ink, (z_w, kern, p_bb, left)


def glow_layer(size_px):
    """Brand-blue radial glow; exactly zero beyond ~62% radius so
    corners stay pure black on every output size."""
    grad = Image.radial_gradient('L').resize((size_px, size_px), Image.BILINEAR)
    # alpha: linear falloff, scaled to ~32% peak, hard zero past V0
    v0 = 158  # of 255; corners/edges measure 255 -> guaranteed zero
    mask = grad.point(lambda v: int(max(0, 255 - int(v * 255 / v0)) * 0.32))
    glow = Image.new('RGBA', (size_px, size_px), BRAND_BLUE + (0,))
    glow.putalpha(mask)
    return glow


def shear(layer, ink):
    """Forward slant about the ink's vertical center."""
    yc = (ink[1] + ink[3]) / 2
    return layer.transform(
        layer.size, Image.AFFINE, (1, SLANT, -SLANT * yc, 0, 1, 0),
        resample=Image.BICUBIC, fillcolor=(0, 0, 0, 0),
    )


def render_master():
    img = Image.new('RGB', (RENDER, RENDER), (0, 0, 0))

    # glow sits slightly above the wordmark (ambient light behind it)
    glow = glow_layer(RENDER)
    img.paste(glow, (0, -48), glow)

    layer, ink, (z_w, kern, p_bb, left) = text_layer(RENDER)
    slanted = shear(layer, ink)

    # blue caret under the P (positions follow the unsheared ink, which
    # the caret shares at baseline height)
    caret_l = left + z_w + kern + p_bb[0]
    caret_r = left + z_w + kern + p_bb[2]
    caret = Image.new('RGBA', (RENDER, RENDER), (0, 0, 0, 0))
    ImageDraw.Draw(caret).rounded_rectangle(
        (caret_l, CARET_TOP * SS, caret_r, CARET_BOTTOM * SS),
        radius=2 * SS, fill=BRAND_BLUE + (255,),
    )

    # dark blue under-echo, then the caret, then the white wordmark
    echo = Image.new('RGBA', (RENDER, RENDER), (0, 0, 0, 0))
    echo.paste(Image.new('RGB', (RENDER, RENDER), ECHO_BLUE), (0, 0), slanted)
    img.paste(echo, (0, 10), echo)
    img.paste(caret, (0, 0), caret)
    img.paste(slanted, (0, 0), slanted)

    # re-center the white wordmark inside the guard band (by construction)
    band = img.crop((0, BAND_TOP * SS, RENDER, RENDER))
    gray = band.convert('L')
    bbox = gray.point(lambda v: 255 if v > 220 else 0).getbbox()
    if bbox:
        center = (bbox[0] + bbox[2]) / 2
        dx = int(round(RENDER / 2 - center))
        if dx:
            img = img.transform(
                (RENDER, RENDER), Image.AFFINE, (1, 0, -dx, 0, 1, 0),
                resample=Image.NEAREST, fillcolor=(0, 0, 0),
            )
    return img


def self_check(master_192):
    band = master_192.crop((0, BAND_TOP, GRID, GRID)).convert('L')
    bbox = band.point(lambda v: 255 if v > 220 else 0).getbbox()
    if not bbox:
        print('SELF-CHECK FAILED: no white pixels in band')
        return False
    w, h = bbox[2] - bbox[0], bbox[3] - bbox[1]
    center = (bbox[0] + bbox[2]) / 2
    ok = w >= 90 and h >= 15 and abs(center - 96) <= 2
    print(f'self-check: white bbox w={w} h={h} center={center:.1f} -> '
          + ('OK' if ok else 'FAIL'))
    return ok


def main():
    repo = os.path.dirname(HERE)
    base = os.path.join(repo, 'app', 'android', 'app', 'src', 'main', 'res')
    if not os.path.isdir(base):
        base = os.path.join(repo, 'android', 'app', 'src', 'main', 'res')

    master = render_master().resize((GRID, GRID), Image.LANCZOS).convert('RGBA')
    self_check(master)
    for dpi, size in SIZES.items():
        out = master.resize((size, size), Image.LANCZOS)
        out.save(os.path.join(base, 'mipmap-' + dpi, 'ic_launcher.png'), 'PNG')
        print('wrote', f'mipmap-{dpi}/ic_launcher.png ({size}x{size})')


if __name__ == '__main__':
    main()
