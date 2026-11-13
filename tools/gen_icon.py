# ZPocket launcher icon pipeline (v5 — artwork-based).
#
# Source: tools/icon/artwork-1024.png (user-supplied 1024px artwork:
# folded-ribbon green "Z." on near-black; the underscore doubles as a
# terminal-cursor cue). This script is the single reproducible path
# from artwork to the five Android mipmap densities.
#
# Guard envelope (app/test/launcher_icon_test.dart, v5):
#   - five mipmap sizes, all pixels alpha=255
#   - corners near-black (every channel <= 12; artwork bg is not pure 0)
#   - 192px master: bright pixels (any channel > 180) form a glyph bbox
#     width>=70, height>=80, centered at x=96 (+-4), y=96 (+-4)
#
# Usage: python tools/gen_icon.py   (requires Pillow)
# Writes android/app/src/main/res/mipmap-*/ic_launcher.png

import os

from PIL import Image

GRID = 192
SIZES = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}

ARTWORK = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       'icon', 'artwork-1024.png')

CORNER_MAX = 12        # corner channels must stay near-black
BRIGHT_MIN = 180       # "bright pixel" threshold (any channel)
BBOX_MIN_W = 70        # guard-test bbox minimums on the 192 master
BBOX_MIN_H = 80
CX = 96
CY = 96
CX_TOL = 4
CY_TOL = 4


def self_check(master):
    """Mirror app/test/launcher_icon_test.dart (v5)."""
    px = master.load()
    w, h = master.size
    problems = []
    for cx, cy in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]:
        if max(px[cx, cy][:3]) > CORNER_MAX:
            problems.append(f'corner {(cx, cy)} too bright: {px[cx, cy]}')
    minx, miny, maxx, maxy = w, h, -1, -1
    for y in range(h):
        for x in range(w):
            r, g, b = px[x, y][:3]
            if max(r, g, b) > BRIGHT_MIN:
                minx, maxx = min(minx, x), max(maxx, x)
                miny, maxy = min(miny, y), max(maxy, y)
    if maxx < 0:
        problems.append('no bright pixels')
    else:
        bw, bh = maxx - minx + 1, maxy - miny + 1
        ccx, ccy = (minx + maxx) / 2, (miny + maxy) / 2
        print(f'self-check: bbox w={bw} h={bh} cx={ccx:.1f} cy={ccy:.1f}')
        if bw < BBOX_MIN_W:
            problems.append(f'glyph width {bw} < {BBOX_MIN_W}')
        if bh < BBOX_MIN_H:
            problems.append(f'glyph height {bh} < {BBOX_MIN_H}')
        if abs(ccx - CX) > CX_TOL:
            problems.append(f'center x {ccx} off {CX}+-{CX_TOL}')
        if abs(ccy - CY) > CY_TOL:
            problems.append(f'center y {ccy} off {CY}+-{CY_TOL}')
    if problems:
        for p in problems:
            print('self-check FAIL:', p)
        return False
    print('self-check: OK')
    return True


def main():
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    base = os.path.join(repo, 'app', 'android', 'app', 'src', 'main', 'res')
    if not os.path.isdir(base):
        base = os.path.join(repo, 'android', 'app', 'src', 'main', 'res')

    artwork = Image.open(ARTWORK).convert('RGB')
    # center-crop to square (defensive; source is already 1024x1024)
    side = min(artwork.size)
    left = (artwork.width - side) // 2
    top = (artwork.height - side) // 2
    artwork = artwork.crop((left, top, left + side, top + side))

    master = artwork.resize((GRID, GRID), Image.LANCZOS).convert('RGBA')
    if not self_check(master):
        raise SystemExit('self-check failed; icons NOT written')
    for dpi, size in SIZES.items():
        out = master.resize((size, size), Image.LANCZOS)
        out.save(os.path.join(base, 'mipmap-' + dpi, 'ic_launcher.png'), 'PNG')
        print('wrote', f'mipmap-{dpi}/ic_launcher.png ({size}x{size})')


if __name__ == '__main__':
    main()
