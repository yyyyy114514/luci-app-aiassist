#!/usr/bin/env python3
# Static scanner: detect ucode-INCOMPATIBLE JS syntax that node --check accepts
# but real ucode (rpcd loader) fails to compile / misbehaves on.
# Usage: scan_ucode.py <file...>
import re, sys

PATTERNS = [
    ("for...of", r'for\s*\(\s*(?:let|const)?\s*\w+\s+of\s'),
    ("spread in array literal", r'\[\s*\.\.\.'),
    ("spread in object literal", r'\{\s*\.\.\.'),
    ("method-style .sort(", r'\.sort\s*\('),
    ("method-style .push(", r'\.push\s*\('),
    ("delete operator", r'\bdelete\s+[a-zA-Z_$][\w$]*\s*(\[[^\]]*\]|\.\w+|;|\)|$)'),
    (r"regex unicode \u escape", r'/.*\\u[0-9a-fA-F]{4}.*/'),
    ("method-style .length", r'\.length\s*[\);\]\s]'),
    ("method-style .join(", r'\.join\s*\('),
    ("method-style .slice(", r'\.slice\s*\('),
    ("destructuring assignment", r'^\s*\{[^}]+\}\s*=|^\s*\[[^\]]+\]\s*=', re.M),
]

def scan(path):
    txt = open(path, encoding="utf-8").read()
    hits = []
    for item in PATTERNS:
        name, pat, *extra = item
        flags = extra[0] if extra else 0
        for m in re.finditer(pat, txt, flags):
            line = txt.count("\n", 0, m.start()) + 1
            snippet = txt[max(0, m.start()-30):m.end()+30].replace("\n", "\\n")
            hits.append((line, name, snippet))
    return hits

total = 0
for f in sys.argv[1:]:
    hits = scan(f)
    if hits:
        print(f"### {f}")
        for line, name, snip in sorted(hits):
            total += 1
            print(f"  L{line}: {name}  ...{snip}...")
if total == 0:
    print("CLEAN: no ucode-incompatible constructs found")
else:
    print(f"\n{total} construct(s) to fix")
    sys.exit(1)
