#!/usr/bin/env python3
"""Zero-page registry tool: check, map, and auto-assign.

    python3 tools/zpcheck.py            # render the ZP map + free slots
    python3 tools/zpcheck.py --alloc    # assign every 'name = ?' in zp.inc
                                        # a free slot (deterministic
                                        # first-fit) and rewrite the file

New ZP variables are declared in src/zp.inc as `name = ?` and given a real
slot by --alloc (asmbuild refuses to build while a '?' is pending, so the
assignment step can't be forgotten). Overlay groups (multiple names, one
address) are deliberate phase-disjoint reuse — never auto-assigned.

Reserved ranges (never allocated):
  $70-$76, $79-$7A, $80-$88   rasteriser-owned scratch (clobbered per line;
                              existing engine symbols inside these ranges
                              are documented phase-disjoint borrowings)
  $D9-$DE                     mul/div hot interface (already assigned)
"""
import re
import sys
import os

ZP_INC = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'src', 'zp.inc')
RESERVED = [(0x70, 0x76), (0x79, 0x7A), (0x80, 0x88)]
DEF_RE = re.compile(r'^([A-Za-z_]\w*)\s*=\s*(\$([0-9A-Fa-f]{1,2})|\?)\s*(;.*)?$')


def parse(path):
    entries = []          # (lineno, name, value|None, comment)
    for i, ln in enumerate(open(path)):
        m = DEF_RE.match(ln.strip())
        if m:
            val = int(m.group(3), 16) if m.group(3) else None
            entries.append((i, m.group(1), val, m.group(4) or ''))
    return entries


SRC_ROOT = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), '..'))


def observed_widths():
    """Widest NAME+K reference found anywhere in the sources.

    The `w=` annotation is hand-maintained and CAN be forgotten — and a
    missing one is invisible until something lands on the high byte of a
    16-bit variable and corrupts it under a phase overlap.  That is the
    whole family of "free-note traps" (zp_bv_entry's $64, zp_vf_vec1's
    $7E, zp_tail_vec's $CB), and on 2026-08-22 it bit again: $5E was
    taken for zp_seg_end_x while zp_anim_p at $5D was 2 bytes wide and
    said so only in prose.  So DERIVE the width from actual use: if any
    source writes `name+1`, the variable is at least 2 bytes."""
    widths = {}
    pat = re.compile(r'\b([A-Za-z_]\w*)\s*\+\s*(\d+)\b')
    for dirpath, _, files in os.walk(SRC_ROOT):
        rel = os.path.relpath(dirpath, SRC_ROOT)
        if rel.split(os.sep)[0] in ('.git', 'build', 'tools'):
            continue                       # (normpath + relpath: SRC_ROOT
                                           #  used to be ".../tools/..", so
                                           #  a substring test skipped EVERY
                                           #  directory and the check was
                                           #  silently dead)
        for fn in files:
            if not fn.endswith(('.s', '.inc', '.asm')):
                continue
            try:
                txt = open(os.path.join(dirpath, fn), errors='ignore').read()
            except OSError:
                continue
            for m in pat.finditer(txt):
                k = int(m.group(2))
                if k < 8:                      # struct strides are not widths
                    n = m.group(1)
                    widths[n] = max(widths.get(n, 1), k + 1)
    return widths


def used_addresses(entries, strict=False):
    used = {}
    obs = observed_widths()
    for _, name, val, com in entries:
        if val is None:
            continue
        m = re.search(r'w=(\d+)', com)
        declared = int(m.group(1)) if m else 1
        width = max(declared, obs.get(name, 1))
        if strict and width > declared:
            print(f'  WIDTH: {name} = ${val:02X} is declared w={declared} but '
                  f'the sources reference {name}+{width - 1} — '
                  f'${val + declared:02X}..${val + width - 1:02X} are NOT free')
        used.setdefault(val, []).append(name)
        for off in range(1, width):
            used.setdefault(val + off, []).append(f'{name}+{off}')
    return used


def free_slots(used):
    res = set()
    for lo, hi in RESERVED:
        res.update(range(lo, hi + 1))
    return [a for a in range(0x100) if a not in used and a not in res]


def main():
    entries = parse(ZP_INC)
    used = used_addresses(entries, strict=True)
    free = free_slots(used)
    pending = [(i, n) for i, n, v, _ in entries if v is None]

    if '--alloc' in sys.argv:
        if not pending:
            print('nothing to allocate')
            return
        lines = open(ZP_INC).readlines()
        for (lineno, name), addr in zip(pending, free):
            lines[lineno] = re.sub(r'=\s*\?', f'= ${addr:02X}', lines[lineno], count=1)
            print(f'{name} -> ${addr:02X}')
        open(ZP_INC, 'w').writelines(lines)
        return

    print(f'{sum(len(v) for v in used.values())} symbols on {len(used)} addresses; '
          f'{len(free)} free slots')
    overlays = {a: n for a, n in used.items() if len(n) > 1}
    print(f'{len(overlays)} overlay groups (deliberate phase-disjoint reuse)')
    if pending:
        print(f'PENDING (run --alloc): {", ".join(n for _, n in pending)}')
    if '--map' in sys.argv:
        for a in sorted(used):
            print(f'  ${a:02X}: {", ".join(used[a])}')
    runs = []
    if free:
        start = prev = free[0]
        for a in free[1:]:
            if a != prev + 1:
                runs.append((start, prev)); start = a
            prev = a
        runs.append((start, prev))
    print('free: ' + ', '.join(f'${a:02X}' if a == b else f'${a:02X}-${b:02X}'
                               for a, b in runs))
    sys.exit(2 if pending else 0)


if __name__ == '__main__':
    main()
