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


def used_addresses(entries):
    used = {}
    for _, name, val, com in entries:
        if val is None:
            continue
        m = re.search(r'w=(\d+)', com)
        width = int(m.group(1)) if m else 1
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
    used = used_addresses(entries)
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
