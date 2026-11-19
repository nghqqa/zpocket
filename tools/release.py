# ZPocket release helper: bump version -> build split APKs -> write
# self-hosted update manifest (kUpdateManifestUrl contract) -> print
# upload commands for your server.
#
# Manifest shape (parsed by app/lib/core/update_check.dart):
#   {"version":"1.0.6","notes":"...",
#    "assets":[{"name":"<file>","url":"<public-url>","sha256":"<64hex>"}]}
# assets.name must contain the ABI string (assetForAbi matches on name).
#
# Usage (from repo root, Flutter on PATH):
#   python tools/release.py --version 1.0.6 --notes "修复与优化" \
#       --base-url https://updates.example.com/updates
# Then upload dist/updates/* to $base-url on your server
# (production: root@159.75.42.106:/home/nghqqa.cn/updates/).
#
# 发版收尾三件套（缺一国内用户就收不到更新）：
#   1. scp dist/updates/* root@159.75.42.106:/home/nghqqa.cn/updates/
#   2. git push origin main --tags   （GitHub Release 用 gh release create）
#   3. git push gitee main --tags    （国内源码镜像 gitee.com/nghqqa/zpocket）

import argparse
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
APP = os.path.join(REPO, 'app')
PUBSPEC = os.path.join(APP, 'pubspec.yaml')
ABI_TAGS = {
    'app-arm64-v8a-release.apk': 'arm64-v8a',
    'app-armeabi-v7a-release.apk': 'armeabi-v7a',
    'app-x86_64-release.apk': 'x86_64',
}


def sh(args, cwd=None):
    # Windows 上 flutter 是 .bat：裸名在无 shell 的 CreateProcess 下不可执行
    if os.name == 'nt' and args and args[0] == 'flutter':
        args = ['flutter.bat'] + args[1:]
    print('+', ' '.join(args))
    subprocess.run(args, cwd=cwd, check=True)


def bump_version(new_version):
    build = datetime.datetime.now().strftime('%Y%m%d') + '01'
    with open(PUBSPEC, encoding='utf-8') as f:
        text = f.read()
    text, n = re.subn(r'^version: .+$', f'version: {new_version}+{build}',
                      text, count=1, flags=re.M)
    if n != 1:
        sys.exit('pubspec.yaml: version line not found')
    with open(PUBSPEC, 'w', encoding='utf-8', newline='') as f:
        f.write(text)
    print(f'pubspec version -> {new_version}+{build}')


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--version', required=True, help='e.g. 1.0.6')
    ap.add_argument('--notes', default='', help='release notes (plain text)')
    ap.add_argument('--base-url', required=True,
                    help='public base URL hosting dist/updates, '
                         'e.g. https://updates.example.com/updates')
    ap.add_argument('--skip-build', action='store_true',
                    help='reuse existing build/app/outputs APKs')
    args = ap.parse_args()

    bump_version(args.version)
    if not args.skip_build:
        sh(['flutter', 'build', 'apk', '--release', '--split-per-abi'], cwd=APP)

    out_dir = os.path.join(APP, 'build', 'app', 'outputs', 'flutter-apk')
    dist = os.path.join(REPO, 'dist', 'updates')
    os.makedirs(dist, exist_ok=True)

    assets = []
    for src_name, abi in ABI_TAGS.items():
        src = os.path.join(out_dir, src_name)
        if not os.path.isfile(src):
            sys.exit(f'missing build output: {src_name}')
        name = f'zpocket-{args.version}-{abi}.apk'
        dst = os.path.join(dist, name)
        with open(src, 'rb') as f, open(dst, 'wb') as g:
            g.write(f.read())
        digest = sha256_of(dst)
        assets.append({
            'name': name,
            'url': f"{args.base_url.rstrip('/')}/{name}",
            'sha256': digest,
        })
        print(f'{name}: sha256={digest}')

    manifest = {
        'version': args.version,
        'notes': args.notes,
        'assets': assets,
    }
    manifest_path = os.path.join(dist, 'manifest.json')
    with open(manifest_path, 'w', encoding='utf-8') as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
    print(f'manifest -> {manifest_path}')
    print('\nUpload everything in dist/updates/ to your server so that')
    print(f'{args.base_url}/manifest.json is publicly reachable, then make')
    print('sure app/lib/core/update_check.dart kUpdateManifestUrl matches')
    print('this base URL and rebuild at least once so clients check it.')


if __name__ == '__main__':
    main()
