#!/usr/bin/env python3
"""Split a translated .s monolith into ordered .include'd subsystem files.

Cut points are (marker_label, out_file) pairs. The cut lands at the banner
comment block immediately preceding the marker label (walking back over
comments/blank lines), and is refused unless the scope/conditional depth is
zero there — so a cut can never land inside .scope/.macro/.if. Byte
identity is preserved because the include order is the original text order.
"""
import os
import re
import sys


def find_cuts(lines, markers):
    # depth per line (scope + macro + if)
    depth = 0
    depth_at = []
    for ln in lines:
        depth_at.append(depth)
        s = ln.strip()
        if s.startswith('.scope') or s.startswith('.macro'):
            depth += 1
        elif s.startswith('.if'):
            depth += 1
        elif s.startswith('.endscope') or s.startswith('.endmacro') or s.startswith('.endif'):
            depth -= 1
    cuts = []
    for label, fname in markers:
        pat = label + ':'
        idx = None
        for i, ln in enumerate(lines):
            if ln.strip() == pat or ln.startswith(pat):
                idx = i
                break
        if idx is None:
            raise SystemExit(f'marker {label} not found')
        # walk back over comment/blank lines (and a wrapping .if directly
        # above the label) to include the banner with the section
        j = idx
        while j > 0 and (lines[j - 1].strip() == '' or lines[j - 1].lstrip().startswith(';')
                         or lines[j - 1].strip().startswith('.if')):
            j -= 1
        if depth_at[j] != 0:
            raise SystemExit(f'cut at {label} lands at depth {depth_at[j]}')
        cuts.append((j, fname))
    if cuts != sorted(cuts):
        raise SystemExit('markers out of order')
    return cuts


def main():
    src, outdir, first_name = sys.argv[1], sys.argv[2], sys.argv[3]
    markers = [tuple(a.split('=')) for a in sys.argv[4:]]
    with open(src) as f:
        lines = f.readlines()
    cuts = find_cuts(lines, markers)
    os.makedirs(outdir, exist_ok=True)
    bounds = [(0, first_name)] + cuts
    incs = []
    # ca65 resolves .include relative to the including file's directory
    rel = os.path.relpath(outdir, os.path.dirname(os.path.abspath(src)))
    for k, (start, fname) in enumerate(bounds):
        end = bounds[k + 1][0] if k + 1 < len(bounds) else len(lines)
        path = os.path.join(outdir, fname)
        with open(path, 'w') as f:
            f.writelines(lines[start:end])
        incs.append(f'.include "{rel}/{fname}"')
        print(f'{path}: {end - start} lines')
    with open(src, 'w') as f:
        f.write('; Auto-split into subsystem files — order matters (bytes are\n')
        f.write('; emitted in include order; segments are set inside the parts).\n')
        f.write('\n'.join(incs) + '\n')
    print(f'{src}: now {len(incs)} includes')


if __name__ == '__main__':
    main()
