#!/usr/bin/env python3
"""Detect exact mojibake byte patterns in Dart files."""
import os

# Known mojibake byte sequences (from double-encoding of UTF-8 through Windows-1252)
PATTERNS = {
    'em-dash': b'\xc3\xa2\xe2\x82\xac\xe2\x80\x9d',
    'bullet': b'\xc3\xa2\xe2\x82\xac\xc2\xa2',
    'ellipsis': b'\xc3\xa2\xe2\x82\xac\xc2\xa6',
    'red-circle': b'\xc3\xb0\xc5\xb8\xe2\x80\x9d\xc2\xb4',
    'checkmark1': b'\xc3\xa2\xc5\x93\xe2\x80\x9c',
    'box-h': b'\xc3\xa2\xe2\x80\x9c\xe2\x82\xac',
    'arrow-r': b'\xc3\xa2\xe2\x80\xa0\xe2\x80\x99',
    'hexagon': b'\xc3\xa2\xc2\xac\xc2\xa1',
}

for root, dirs, files in os.walk('lib'):
    for f in files:
        if not f.endswith('.dart'):
            continue
        path = os.path.join(root, f)
        with open(path, 'rb') as fh:
            data = fh.read()
        for name, pat in PATTERNS.items():
            c = data.count(pat)
            if c:
                print(f'{path}  {name}: {c}')

# Also dump unique non-ASCII byte sequences from home_screen.dart to identify patterns
print("\n--- Scanning home_screen.dart for non-ASCII sequences ---")
with open('lib/screens/home_screen.dart', 'rb') as f:
    data = f.read()

i = 0
seen = set()
while i < len(data):
    b = data[i]
    if b > 0x7E:
        j = i
        while j < len(data) and data[j] > 0x7E:
            j += 1
        seq = data[i:j]
        if seq not in seen:
            seen.add(seq)
            # find context
            ctx_start = max(0, i - 15)
            ctx_end = min(len(data), j + 15)
            ctx = data[ctx_start:ctx_end]
            print(f'  byte {i}: {seq.hex(" ")} => ctx: {ctx!r}')
        i = j
    else:
        i += 1
