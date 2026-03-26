import os
def fix_encoding(filepath):
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
    except Exception:
        return
    changed = False
    replacements = {
        'â€”': '—',
        'â€¦': '...',
        'â‰ˆ': '≈',
        'â†’': '→',
        'â€¢': '•',
        'â”€': '─'
    }
    for old, new in replacements.items():
        if old in content:
            changed = True
            content = content.replace(old, new)
    if changed:
        with open(filepath, 'w', encoding='utf-8') as f:
            f.write(content)
        print(f'Fixed {filepath}')

for root, _, files in os.walk('lib'):
    for file in files:
        if file.endswith('.dart'):
            fix_encoding(os.path.join(root, file))
