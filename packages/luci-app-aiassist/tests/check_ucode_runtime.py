#!/usr/bin/env python3
# Runtime-parity scanners: catch what node --check and scan_ucode.py cannot.
# Real OpenWrt ucode executes/compiles the module and fails at *runtime* on:
#   1. forward calls - ucode has NO function hoisting: a function must be
#      defined before anything that calls it, else "Reference error: access
#      to undeclared variable <name>" (unlike JS).
#   2. non-existent globals - e.g. float()/double()/rand() are NOT ucode core
#      builtins (float/double -> use unary +; rand -> use clock()).
# Usage: check_ucode_runtime.py <file.uc ...>
import re, sys

# ucode core builtin globals (ucode-lang.org module-core, 71 functions)
UCODE_GLOBALS = set('''arrtoip assert b64dec b64enc call chr clock die exists exit filter gc getenv gmtime
hex hexdec hexenc include index int iptoarr join json keys lc length loadfile loadstring localtime ltrim
map match max min ord pop print printf proto push regexp render replace require reverse rindex rtrim
shift signal sleep slice sort sourcepath splice split sprintf substr system time timegm timelocal trace
trim type uc uchr uniq unshift values warn wildcard'''.split())

# stdlib modules usable via import { x } from 'fs' / 'uci'
FS_MODS = set('''open close read write seek tell flush readline readfile writefile popen mkdir rmdir unlink
lsdir stat lstat realpath access basename dirname glob readdir chmod'''.split())
UCI_MODS = {'cursor'}

def strip_comments_and_strings(line):
    """Return a version of `line` with // comments, quoted strings and regex
    literals blanked (best-effort; regex detection only triggers after a space
    or start-of-line to avoid confusing division with a regex)."""
    out = list(line)
    i, n = 0, len(line)
    while i < n:
        c = line[i]
        if c == '/' and i + 1 < n and line[i + 1] == '/':
            for j in range(i, n):
                out[j] = ' '
            break
        if c in ('"', "'"):
            q = c
            j = i + 1
            while j < n:
                if line[j] == '\\':
                    j += 2
                    continue
                if line[j] == q:
                    break
                j += 1
            for k in range(i, min(j + 1, n)):
                out[k] = ' '
            i = j + 1
            continue
        # regex literal: /<...>/ - only when preceded by whitespace or start
        if c == '/' and (i == 0 or line[i - 1] in ' \t=(,'):
            j = i + 1
            while j < n:
                if line[j] == '\\':
                    j += 2
                    continue
                if line[j] == '/':
                    break
                j += 1
            if j < n and line[j] == '/':
                for k in range(i, j + 1):
                    out[k] = ' '
                i = j + 1
                continue
        i += 1
    return ''.join(out)

def scan(path):
    txt = open(path, encoding='utf-8').read()
    lines = txt.split('\n')
    defs = {}
    imported = set()
    locals_ = set()
    # import spans multiple lines: import { a, b } from 'mod' (dot-name ok)
    for m in re.finditer(r'import\s*\{([^}]*)\}\s*from\s*[\'"]([^\'"]+)[\'"]', txt, re.S):
        imported |= {n.strip() for n in m.group(1).split(',') if n.strip()}
    for i, ln in enumerate(lines, 1):
        m = re.match(r'^\s*(?:export\s+)?function\s+([a-zA-Z_]\w*)', ln)
        if m:
            defs[m.group(1)] = i
        for m2 in re.finditer(r'\b(?:let|const|var)\s+([a-zA-Z_]\w*)', ln):
            locals_.add(m2.group(1))
        # function parameters are also known names
        m3 = re.match(r'^\s*(?:export\s+)?function\s+\w+\s*\(([^)]*)\)', ln)
        if m3:
            locals_ |= {p.strip() for p in m3.group(1).split(',') if p.strip()}
    known = UCODE_GLOBALS | FS_MODS | UCI_MODS | set(defs) | imported | locals_
    issues = []
    for i, ln in enumerate(lines, 1):
        code = strip_comments_and_strings(ln)
        for m in re.finditer(r'\b([a-zA-Z_]\w*)\s*\(', code):
            name = m.group(1)
            prev = code[:m.start()]
            if re.search(r'function\s+$', prev):
                continue  # this is the definition itself
            if re.search(r'\.\s*$', prev):
                continue  # method call: obj.name(...)
            if name in ('if', 'for', 'while', 'switch', 'catch', 'typeof', 'return', 'function'):
                continue
            if name in defs and i < defs[name]:
                issues.append((i, 'forward-call', f'{name}() called before its definition at line {defs[name]}'))
            elif name not in known:
                issues.append((i, 'undeclared-global', f'{name}() is not a ucode core builtin/module/project function'))
    return issues

total = 0
for f in sys.argv[1:]:
    hits = scan(f)
    if hits:
        print(f'### {f}')
        for line, kind, msg in hits:
            total += 1
            print(f'  L{line} [{kind}] {msg}')
if total == 0:
    print('CLEAN: no forward calls, no undeclared globals')
else:
    print(f'\n{total} issue(s) - ucode would fail at import/runtime')
    sys.exit(1)