#!/usr/bin/env python3
"""Fix mojibake (double-encoded UTF-8) across all Dart source files."""
import os
import re

# Exact mojibake byte sequences found in the codebase -> clean ASCII replacements
REPLACEMENTS = [
    # Em dash (double-encoded: c3 a2 e2 82 ac e2 80 9d)
    (b'\xc3\xa2\xe2\x82\xac\xe2\x80\x9d', b'--'),
    # Bullet (double-encoded: c3 a2 e2 82 ac c2 a2)
    (b'\xc3\xa2\xe2\x82\xac\xc2\xa2', b'*'),
    # Ellipsis (double-encoded: c3 a2 e2 82 ac c2 a6)
    (b'\xc3\xa2\xe2\x82\xac\xc2\xa6', b'...'),
    # Checkmark (double-encoded: c3 a2 c5 93 e2 80 9c)
    (b'\xc3\xa2\xc5\x93\xe2\x80\x9c', b'OK'),
    # Right arrow (double-encoded: c3 a2 e2 80 a0 e2 80 99)
    (b'\xc3\xa2\xe2\x80\xa0\xe2\x80\x99', b'->'),
    # Red circle emoji (double-encoded: c3 b0 c5 b8 e2 80 9d c2 b4)
    (b'\xc3\xb0\xc5\xb8\xe2\x80\x9d\xc2\xb4', b''),
    # Box drawing horizontal mojibake (c3 a2 e2 80 9d e2 82 ac) used in comment separators
    (b'\xc3\xa2\xe2\x80\x9d\xe2\x82\xac', b'-'),
]

count = 0
for root, dirs, files in os.walk('lib'):
    for f in files:
        if not f.endswith('.dart'):
            continue
        path = os.path.join(root, f)
        with open(path, 'rb') as fh:
            data = fh.read()
        original = data
        for old, new in REPLACEMENTS:
            data = data.replace(old, new)
        if data != original:
            with open(path, 'wb') as fh:
                fh.write(data)
            count += 1
            print(f'Fixed: {path}')

print(f'\nTotal files fixed: {count}')
