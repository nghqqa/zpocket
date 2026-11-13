# Extract zh literals passed to Text(...) in lib/ui (joining adjacent
# string literals, which Dart concatenates at compile time) that have no
# exact entry in custom_l10n.dart / official_l10n.g.dart and are not
# covered by _L10nPattern regexes. L10n completion batch, 2026-11-13.
import glob
import io
import re
import sys

sys.stdout.reconfigure(encoding='utf-8')

cust = io.open('app/lib/core/custom_l10n.dart', encoding='utf-8').read()
off = io.open('app/lib/core/official_l10n.g.dart', encoding='utf-8').read()
patterns = re.findall(r"_L10nPattern\(RegExp\(\s*r'([^']*)'\)", cust)


def has_exact(key):
    needle = "'" + key + "':"
    return needle in cust or needle in off


def covered_by_pattern(key):
    for p in patterns:
        try:
            if re.match(p, key):
                return True
        except re.error:
            continue
    return False


LIT = re.compile(r"'((?:[^'\\\n]|\\.)*)'")


def combined_literals(s, start):
    """Collect adjacent '...' literals from `start` (at first literal),
    stopping at the first non-literal/non-whitespace token."""
    out = []
    i = start
    while True:
        m = LIT.match(s, i)
        if not m:
            break
        out.append(m.group(1))
        i = m.end()
        j = i
        while j < len(s) and s[j] in ' \t\n':
            j += 1
        if j < len(s) and s[j] == "'":
            i = j
            continue
        i = j
        break
    return ''.join(out), i


missing_exact = {}
missing_interp = {}
files = glob.glob('app/lib/ui/**/*.dart', recursive=True)
for f in files:
    s = io.open(f, encoding='utf-8').read()
    for mm in re.finditer(r"(?:Text\(\s*|tr\(\s*)'", s):
        start = mm.end() - 1
        key, _end = combined_literals(s, start)
        if not re.search(r'[\u4e00-\u9fff]', key):
            continue
        rel = f.replace('app' + '/', '').replace('\\', '/')
        line = s[: mm.start()].count('\n') + 1
        loc = f'{rel}:{line}'
        if '$' in key:
            if not covered_by_pattern(key):
                missing_interp.setdefault(key, []).append(loc)
            continue
        if has_exact(key):
            continue
        missing_exact.setdefault(key, []).append(loc)

print('== missing exact entries:', len(missing_exact), '==')
for k in sorted(missing_exact):
    print(repr(k), '@', ','.join(missing_exact[k][:1]))
print()
print('== interpolated without pattern:', len(missing_interp), '==')
for k in sorted(missing_interp):
    print(repr(k), '@', ','.join(missing_interp[k][:1]))
