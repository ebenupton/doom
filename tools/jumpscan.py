#!/usr/bin/env python3
"""Static scan for degenerate control transfers.

  NEXT   a JMP/branch whose target is the very next instruction — the
         transfer is pure cost (3 cycles for a JMP, 2-3 for a branch).
  CHAIN  a JMP whose target is itself an unconditional JMP — the first
         hop can go straight to the final destination (trampoline chain).
  Both survive refactoring silently: the code between shrinks away and
  nobody re-reads the jump.
"""
import os, re, sys
ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
SKIP = {'.git', 'build', 'tools', 'virus', 'line-test', 'line-test-a',
        'line-test-new', 'tube'}
LABEL = re.compile(r'^([A-Za-z_@][\w@]*):')
XFER = re.compile(r'^(JMP|BEQ|BNE|BCC|BCS|BMI|BPL|BVC|BVS|BRA)\s+'
                  r'([A-Za-z_@][\w@]*)\s*$')

files = []
for dp, _, fs in os.walk(ROOT):
    if os.path.relpath(dp, ROOT).split(os.sep)[0] in SKIP:
        continue
    for fn in sorted(fs):
        if fn.endswith(('.s', '.asm')):
            files.append(os.path.join(dp, fn))

nxt, chain = [], []
for path in files:
    rel = os.path.relpath(path, ROOT)
    code = []
    for i, ln in enumerate(open(path, errors='ignore'), 1):
        c = ln.split(';')[0].strip()
        if c:
            code.append((i, c))
    labels_at = {}
    for i, c in code:
        m = LABEL.match(c)
        if m:
            labels_at.setdefault(m.group(1), i)
    for k, (i, c) in enumerate(code):
        m = XFER.match(c)
        if not m:
            continue
        op, tgt = m.group(1), m.group(2)
        # NEXT: skip forward over label-only lines
        for j in range(k + 1, min(k + 8, len(code))):
            lm = LABEL.match(code[j][1])
            if lm:
                if lm.group(1) == tgt:
                    nxt.append((rel, i, op, tgt))
                    break
                continue
            break
        # CHAIN: does the target label sit on an unconditional JMP?
        if op == 'JMP' and tgt in labels_at:
            tl = labels_at[tgt]
            for j, (i2, c2) in enumerate(code):
                if i2 == tl:
                    for q in range(j, min(j + 4, len(code))):
                        if LABEL.match(code[q][1]):
                            continue
                        m2 = re.fullmatch(r'JMP\s+([A-Za-z_@][\w@]*)', code[q][1])
                        if m2 and m2.group(1) != tgt:
                            chain.append((rel, i, tgt, m2.group(1)))
                        break
                    break

print(f'NEXT — transfer to the immediately following instruction: {len(nxt)}')
for h in nxt:
    print(f'   {h[0]}:{h[1]}  {h[2]} {h[3]}')
print(f'\nCHAIN — JMP landing on another JMP: {len(chain)}')
for h in chain:
    print(f'   {h[0]}:{h[1]}  JMP {h[2]} -> JMP {h[3]}')
