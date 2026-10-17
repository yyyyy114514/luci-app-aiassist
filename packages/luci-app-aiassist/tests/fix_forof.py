#!/usr/bin/env python3
# Convert ucode-incompatible `for (let X of EXPR) BODY` into index loops:
#   let __arr = EXPR;
#   for (let __i = 0; __i < length(__arr); __i++) {
#       let X = __arr[__i];
#       BODY
#   }
# EXPR may contain nested ( [ { and string literals; the header's closing ')'
# is found with a bracket stack. Single-statement bodies are wrapped too.
# Usage: fix_forof.py <file...> (in-place rewrite)
import re, sys

def skip_str(s, i):
    q = s[i]
    j = i + 1
    while j < len(s):
        if s[j] == '\\':
            j += 2
            continue
        if s[j] == q:
            return j + 1
        j += 1
    return j

def find_expr_end(s, start):
    """s[start:] begins the expression after 'of'. Return index of the for-header ')'."""
    stack = []
    j = start
    pairs = {')': '(', ']': '[', '}': '{'}
    while j < len(s):
        c = s[j]
        if c in "'\"`":
            j = skip_str(s, j)
            continue
        if c in '([{':
            stack.append(c)
        elif c in ')]}':
            if stack and stack[-1] == pairs[c]:
                stack.pop()
            elif not stack and c == ')':
                return j
        j += 1
    return -1

def find_brace(s, i):
    depth = 0
    j = i
    while j < len(s):
        c = s[j]
        if c in "'\"`":
            j = skip_str(s, j)
            continue
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return j
        j += 1
    return -1

def collect_indented(txt, st, n, ind0):
    """Collect a compound header line (starting at st, indent ind0) plus all
    following lines indented deeper than ind0. Returns (text, next_i)."""
    eol = txt.find('\n', st)
    if eol < 0:
        eol = n
    head = txt[st:eol + 1]
    i = eol + 1
    body = []
    while i < n:
        j = i
        while j < n and txt[j] in ' \t':
            j += 1
        ind = j - i
        if j < n and txt[j] != '\n' and ind > ind0:
            e2 = txt.find('\n', j)
            if e2 < 0:
                e2 = n
            body.append(txt[i:e2 + 1])
            i = e2 + 1
        else:
            break
    return head + ''.join(body), i

def fix_for_of(txt):
    # start numbering past any __arrN already present (safe across repeated runs)
    used = [int(m) for m in re.findall(r'__arr(\d+)', txt)]
    counter = (max(used) + 1) if used else 0
    out = []
    i = 0
    n = len(txt)
    changed = 0
    while i < n:
        m = re.match(r'for\s*\(\s*(?:let|const)\s+(\w+)\s+of\s+', txt[i:])
        if not m:
            out.append(txt[i])
            i += 1
            continue
        var = m.group(1)
        expr_start = i + m.end()
        rp = find_expr_end(txt, expr_start)
        if rp < 0:
            out.append(txt[i])
            i += 1
            continue
        expr = txt[expr_start:rp].strip()
        body_start = rp + 1
        j = body_start
        while j < n and txt[j] in ' \t\r\n':
            j += 1
        if j < n and txt[j] == '{':
            br = find_brace(txt, j)
            if br < 0:
                out.append(txt[i])
                i += 1
                continue
            body = txt[body_start:br + 1]
            next_i = br + 1
        else:
            # single-statement body: skip whitespace/newlines to the statement
            st = j
            if st >= n:
                body, next_i = '', st
            else:
                eol = txt.find('\n', st)
                if eol < 0:
                    eol = n
                line = txt[st:eol].rstrip()
                if line.endswith(';'):
                    body = txt[st:eol]
                    next_i = eol
                else:
                    # compound header (e.g. `if (...)`) whose body is on deeper-indented lines
                    ind0 = 0
                    p = st
                    while p > 0 and txt[p - 1] in ' \t':
                        p -= 1
                        ind0 += 1
                    body, next_i = collect_indented(txt, st, n, ind0)

        indent = ''
        for c in txt[i:]:
            if c in ' \t':
                indent += c
            else:
                break

        an = f'__arr{counter}'
        ii = f'__i{counter}'
        counter += 1

        new = (
            f'{indent}let {an} = {expr};\n'
            f'{indent}for (let {ii} = 0; {ii} < length({an}); {ii}++) {{\n'
            f'{indent}\tlet {var} = {an}[{ii}];\n'
            f'{indent}\t{body.strip()}\n'
            f'{indent}}}\n'
        )
        out.append(new)
        changed += 1
        i = next_i
    return ''.join(out), changed

for f in sys.argv[1:]:
    txt = open(f, encoding='utf-8').read()
    fixed, n = fix_for_of(txt)
    if n:
        open(f, 'w', encoding='utf-8', newline='\n').write(fixed)
        print(f"{f}: converted {n} for...of")
    else:
        print(f"{f}: no for...of")