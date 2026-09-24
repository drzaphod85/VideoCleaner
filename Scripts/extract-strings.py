#!/usr/bin/env python3
"""Collects every localizable English string in Sources/ (L("…") calls and SwiftUI literal initializers)
and checks that each translation in Resources/*.lproj/Localizable.strings covers them.

    Scripts/extract-strings.py            # list missing/unused keys per language
    Scripts/extract-strings.py --keys     # print all keys
"""
import glob, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIT = r'"((?:[^"\\]|\\.)*)"'
PATTERNS = [
    r'\bL\(' + LIT,
    r'(?<![\w.])(?:Text|Button|Label|Toggle|Section|Menu|Picker|LabeledContent|TextField|ContentUnavailableView|Link|CommandMenu)\(' + LIT,
    r'\.help\(' + LIT,
    r'prompt: Text\(' + LIT,
    r'case \w+ = ' + LIT,  # enum raw values shown via LocalizedStringKey
]

def keys():
    found = set()
    for path in glob.glob(os.path.join(ROOT, 'Sources', '**', '*.swift'), recursive=True):
        src = open(path, encoding='utf-8').read()
        for p in PATTERNS:
            for m in re.finditer(p, src):
                k = m.group(1)
                if '\\(' in k:
                    print(f'warning: interpolated literal (use L()): {k}  [{os.path.basename(path)}]', file=sys.stderr)
                    continue
                if k and re.search(r'[A-Za-z]', k):
                    found.add(k)
    return found

def parse_strings(path):
    text = open(path, encoding='utf-8').read()
    return dict(re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', text, re.M))

if __name__ == '__main__':
    ks = keys()
    if '--keys' in sys.argv:
        for k in sorted(ks): print(k)
        sys.exit(0)
    ok = True
    for f in sorted(glob.glob(os.path.join(ROOT, 'Resources', '*.lproj', 'Localizable.strings'))):
        lang = os.path.basename(os.path.dirname(f))
        tr = parse_strings(f)
        missing = sorted(ks - tr.keys())
        unused = sorted(tr.keys() - ks)
        print(f'{lang}: {len(tr)} strings, {len(missing)} missing, {len(unused)} unused')
        for k in missing: print(f'  missing: {k}'); ok = False
        for k in unused: print(f'  unused:  {k}')
    sys.exit(0 if ok else 1)
