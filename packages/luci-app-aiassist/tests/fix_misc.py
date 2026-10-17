#!/usr/bin/env python3
# Second-stage fixes (after fix_forof) for ucode-incompatible constructs:
#  - array literal spread [ ...A ]  -> copy via loop
#  - method-style .sort(fn)         -> global sort(arr, fn)
#  - `delete obj[k]`                -> remove_key() helper
#  - regex \uXXXX escapes           -> ord()-based char counting (estimate_tokens)
# In-place rewrite. Usage: fix_misc.py <file...>
import re, sys

def fix_lib(txt, path):
    # 1. add copy_array/remove_key helpers after randstr() block if not present
    if 'function copy_array(' not in txt:
        anchor = 'function remove_key('
        if anchor not in txt:
            # insert helpers right before '// ---------------------------------------------------------------- configuration'
            marker = '// ---------------------------------------------------------------- configuration'
            helpers = (
                '// ucode has no array/object spread and no `delete` operator: use these helpers\n'
                'function copy_array(a) {\n'
                '\tlet r = [];\n'
                '\tfor (let i = 0; i < length(a); i++)\n'
                '\t\tpush(r, a[i]);\n'
                '\treturn r;\n'
                '}\n\n'
                'function remove_key(obj, key) {\n'
                '\tlet r = {};\n'
                '\tfor (let k in obj)\n'
                '\t\tif (k != key)\n'
                '\t\t\tr[k] = obj[k];\n'
                '\treturn r;\n'
                '}\n\n'
            )
            if marker in txt:
                txt = txt.replace(marker, helpers + marker, 1)
    # 2. spread
    txt = txt.replace('cfg.exec_allow = [ ...DEFAULT_ALLOW ];', 'cfg.exec_allow = copy_array(DEFAULT_ALLOW);')
    txt = txt.replace('cfg.view_paths = [ ...VIEW_PATHS ];', 'cfg.view_paths = copy_array(VIEW_PATHS);')
    # 3. sort
    txt = re.sub(r'(\w+)\.sort\(\(', r'sort(\1, (', txt)
    # 4. delete obj[key] -> rebuild object without the key (ucode has no delete)
    txt = txt.replace('delete s.snapshots[t];', 's.snapshots = remove_key(s.snapshots, t);')
    txt = txt.replace('delete s.snapshots[turn];', 's.snapshots = remove_key(s.snapshots, turn);')
    # 5. estimate_tokens regex (this file)
    old = re.search(r'function estimate_tokens\(text\) \{[^}]*?return int\(cjk \* 1\.5 \+ other / 4 \+ 0\.999\);\n\}', txt, re.S)
    if old:
        new_fn = (
            'function estimate_tokens(text) {\n'
            '\ttext = \'\' + text;\n'
            '\tlet cjk = 0;\n'
            '\tfor (let i = 0; i < length(text); i++) {\n'
            '\t\tlet c = ord(substr(text, i, 1));\n'
            '\t\tif ((c >= 0x4e00 && c <= 0x9fff) || (c >= 0x3400 && c <= 0x4dbf))\n'
            '\t\t\tcjk++;\n'
            '\t}\n'
            '\tlet other = length(text) - cjk;\n'
            '\treturn int(cjk * 1.5 + other / 4 + 0.999);\n'
            '}'
        )
        txt = txt.replace(old.group(0), new_fn, 1)
    return txt

def fix_core(txt, path):
    old = re.search(r'function estimate_tokens\(text\) \{[^}]*?return int\(cjk \* 1\.5 \+ other / 4 \+ 0\.999\);\n\}', txt, re.S)
    if old:
        new_fn = (
            'function estimate_tokens(text) {\n'
            '\ttext = \'\' + (text || \'\');\n'
            '\tlet cjk = 0;\n'
            '\tfor (let i = 0; i < length(text); i++) {\n'
            '\t\tlet c = ord(substr(text, i, 1));\n'
            '\t\tif ((c >= 0x4e00 && c <= 0x9fff) || (c >= 0x3400 && c <= 0x4dbf))\n'
            '\t\t\tcjk++;\n'
            '\t}\n'
            '\tlet other = length(text) - cjk;\n'
            '\treturn int(cjk * 1.5 + other / 4 + 0.999);\n'
            '}'
        )
        txt = txt.replace(old.group(0), new_fn, 1)
    return txt

def fix_proto(txt, path):
    old = 'last.content = [ ...last.content, ...m.content ];'
    if old in txt:
        new = (
            '// append m.content blocks onto last.content (ucode has no array spread)\n'
            '\t\t\tlet __src = m.content;\n'
            '\t\t\tfor (let __j = 0; __j < length(__src); __j++)\n'
            '\t\t\t\tpush(last.content, __src[__j]);'
        )
        txt = txt.replace(old, new, 1)
    return txt

for f in sys.argv[1:]:
    txt = open(f, encoding='utf-8').read()
    if 'lib.uc' in f:
        txt = fix_lib(txt, f)
    elif 'core.uc' in f:
        txt = fix_core(txt, f)
    elif 'proto.uc' in f:
        txt = fix_proto(txt, f)
    open(f, 'w', encoding='utf-8', newline='\n').write(txt)
    print(f"fixed {f}")
