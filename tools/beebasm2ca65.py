#!/usr/bin/env python3
"""Mechanical beebasm -> ca65 translator for the engine sources.

One-time conversion scaffolding for the linker port. The output is verified
BYTE-IDENTICAL against the beebasm binaries before the .s files become the
source of truth, so any translation error is caught by the build, not by
the renderer.

Dialect handled (exactly what the engine files use — not general beebasm):
  - '\\' comments             -> ';'
  - 'stmt : stmt' lines       -> one statement per line
  - '.label' definitions      -> 'label:'
  - '{' / '}' scopes          -> '.scope' / '.endscope'
  - ORG addr                  -> .segment "NAME"   (per --seg map)
  - SAVE ...                  -> dropped (ld65 config writes the files)
  - EQUB/EQUW                 -> .byte/.word
  - SKIP n                    -> .res n
  - ASSERT x                  -> .assert x, error
  - IF/ELIF/ELSE/ENDIF        -> .if/.elseif/.else/.endif
  - FOR i,a,b ... NEXT        -> .repeat (b-a+1) ... .endrepeat  (i unused)
  - MACRO/ENDMACRO            -> .macro/.endmacro
  - CPU 1                     -> .setcpu "65C02"
  - P%                        -> *
  - &hex                      -> $hex
  - INC A / DEC A             -> ina / dea  (65C02 implicit-A spellings)

Usage:
  beebasm2ca65.py in.asm out.s --seg 0xE940=ANG [--seg 0x3400=ANG_BK]
Each --seg maps an ORG address to a segment name.
"""
import re
import sys


def split_statements(code):
    """Split a beebasm code fragment on ':' statement separators."""
    parts = []
    cur = []
    for ch in code:
        if ch == ':':
            parts.append(''.join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    parts.append(''.join(cur).strip())
    return [p for p in parts if p]


LABEL_RE = re.compile(r'^\.([A-Za-z_]\w*)$')
ORG_RE = re.compile(r'^ORG\s+(.+)$', re.I)
FOR_RE = re.compile(r'^FOR\s+(\w+)\s*,\s*([^,]+)\s*,\s*(.+)$', re.I)
CONST_RE = re.compile(r'^([A-Za-z_]\w*)\s*=\s*(.+)$')


def conv_expr(e):
    e = e.replace('&', '$')
    # P% -> * (current PC; both are the address of the current instruction)
    e = re.sub(r'\bP%', '*', e)
    # build defines are command-line globals; inside .scope/.macro a bare name
    # would be an (unresolvable-forward) scope-local reference
    e = re.sub(r'\b(C02|BANKED|EMIT_LINES)\b', r'::\1', e)
    # beebasm booleans (TRUE = -1 in beebasm, but engine code only tests
    # truthiness; 1 keeps .if semantics identical)
    e = re.sub(r'\bTRUE\b', '1', e)
    e = re.sub(r'\bFALSE\b', '0', e)
    return e


def translate(lines, segmap, padset=()):
    out = []
    scope_depth = 0
    for raw in lines:
        line = raw.rstrip('\n')
        # split comment (first '\' or ';' not in a char literal — the engine
        # files never put these inside quotes)
        cm = re.search(r"[\\;]", line)
        code, comment = (line[:cm.start()], line[cm.start():]) if cm else (line, '')
        if comment.startswith('\\'):
            comment = ';' + comment[1:]
        code = code.strip()
        if not code:
            out.append(comment if comment else '')
            continue

        stmts = split_statements(code)
        # '.label STMT' on one line -> label def + statement
        expanded = []
        for st in stmts:
            m = re.match(r'^\.([A-Za-z_]\w*)\s+(\S.*)$', st)
            if m and not re.match(r'^\.(if|else|elseif|endif)\b', st, re.I):
                expanded.append('.' + m.group(1))
                expanded.append(m.group(2))
            else:
                expanded.append(st)
        emitted = []
        for st in expanded:
            m = LABEL_RE.match(st)
            if m:
                emitted.append(f'{m.group(1)}:')
                continue
            if st == '{':
                emitted.append('.scope')
                scope_depth += 1
                continue
            if st == '}':
                emitted.append('.endscope')
                scope_depth -= 1
                continue
            u = st.upper()
            m = ORG_RE.match(st)
            if m:
                addr = conv_expr(m.group(1).strip())
                val = int(addr.replace('$', '0x'), 16) if addr.startswith('$') else None
                name = segmap.get(val)
                if name is None:
                    if val in padset:
                        # mid-region address pin: beebasm ORG-forward leaves a
                        # zero gap in the SAVEd image; .res zero-fills the same
                        emitted.append(f'.res {addr} - *')
                        continue
                    raise SystemExit(f'no --seg mapping for ORG {addr}')
                emitted.append(f'.segment "{name}"')
                continue
            if u.startswith('SAVE'):
                emitted.append(f'; (ld65 writes this: {st})')
                continue
            if u.startswith('EQUB'):
                emitted.append('.byte ' + conv_expr(st[4:].strip()))
                continue
            if u.startswith('EQUW'):
                emitted.append('.word ' + conv_expr(st[4:].strip()))
                continue
            if u.startswith('SKIP'):
                emitted.append('.res ' + conv_expr(st[4:].strip()))
                continue
            if u.startswith('ASSERT'):
                emitted.append(f'.assert {conv_expr(st[6:].strip())}, error')
                continue
            if u == 'ENDIF':
                emitted.append('.endif'); continue
            if u == 'ELSE':
                emitted.append('.else'); continue
            if u.startswith('ELIF'):
                emitted.append('.elseif ' + conv_expr(st[4:].strip())); continue
            if u.startswith('IF '):
                emitted.append('.if ' + conv_expr(st[3:].strip())); continue
            m = FOR_RE.match(st)
            if m:
                var, a, b = m.group(1), m.group(2).strip(), m.group(3).strip()
                emitted.append(f'.repeat ({conv_expr(b)})-({conv_expr(a)})+1')
                continue
            if u == 'NEXT':
                emitted.append('.endrepeat'); continue
            if u.startswith('MACRO'):
                emitted.append('.macro ' + st[5:].strip()); continue
            if u == 'ENDMACRO':
                emitted.append('.endmacro'); continue
            if u == 'CPU 1':
                emitted.append('.setcpu "65C02"'); continue
            if u == 'INC A':
                emitted.append('ina'); continue
            if u == 'DEC A':
                emitted.append('dea'); continue
            m = CONST_RE.match(st)
            if m and not re.match(r'^(LDA|LDX|LDY|STA|STX|STY|ADC|SBC|CMP|CPX|CPY|AND|ORA|EOR|ASL|LSR|ROL|ROR|INC|DEC|BIT|JMP|JSR)$',
                                  m.group(1), re.I):
                emitted.append(f'{m.group(1)} = {conv_expr(m.group(2))}')
                continue
            # plain instruction
            emitted.append(conv_expr(st))

        if len(emitted) == 1 and comment:
            out.append(f'{emitted[0]:<40s}{comment}')
        else:
            out.extend(emitted)
            if comment:
                out.append(comment)
    if scope_depth != 0:
        raise SystemExit(f'unbalanced scopes: depth {scope_depth} at EOF')
    return out


def main():
    args = sys.argv[1:]
    segmap = {}
    padset = set()
    rest = []
    i = 0
    while i < len(args):
        if args[i] == '--seg':
            addr, name = args[i + 1].split('=')
            segmap[int(addr, 16)] = name
            i += 2
        elif args[i] == '--pad':
            padset.add(int(args[i + 1], 16))
            i += 2
        else:
            rest.append(args[i]); i += 1
    src, dst = rest
    with open(src) as f:
        lines = f.readlines()
    out = translate(lines, segmap, padset)
    with open(dst, 'w') as f:
        f.write('\n'.join(out) + '\n')
    print(f'{src} -> {dst}: {len(lines)} lines in, {len(out)} out')


if __name__ == '__main__':
    main()
