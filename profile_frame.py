"""Profile a full pure-6502 frame by routine, using py65 cycle deltas
bucketed by the label enclosing each instruction's PC.

Symbols come from the beebasm -v listings of bsp_render.asm and
span_clip.asm; the rasteriser ($A900+) is one bucket.

Usage: profile_frame.py [px py ab]   (default: 3-position summary)
"""
import os, re, subprocess, bisect
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import trace_compare as tc


def toplevel_labels(asm):
    """Labels defined at brace depth 0 in the source = routine starts."""
    out = set()
    depth = 0
    for line in open(asm):
        s = line.strip()
        if s.startswith('.') and depth == 0:
            m = re.match(r'\.([A-Za-z_][A-Za-z0-9_]*)', s)
            if m:
                out.add(m.group(1))
        depth += s.count('{') - s.count('}')
    return out


def build_symbols():
    syms = []
    for asm in ('bsp_render.asm', 'span_clip.asm'):
        top = toplevel_labels(asm)
        out = subprocess.run(['./beebasm', '-i', asm, '-v'],
                             capture_output=True, text=True).stdout
        for m in re.finditer(r'\.([A-Za-z_][A-Za-z0-9_]*)\n\s+([0-9A-F]{4})', out):
            if m.group(1) in top:
                syms.append((int(m.group(2), 16), m.group(1)))
    syms.append((0xA900, '<rasteriser>'))
    syms.append((0xFF00, '<halt>'))
    syms.sort()
    addrs, names = [], []
    for a, n in syms:
        if addrs and addrs[-1] == a:
            continue
        addrs.append(a)
        names.append(n)
    return addrs, names


def profile(px, py, ab, addrs, names):
    _ = dw.Instrumented6502Spans()
    sc = dw._span_clip_6502
    tc.setup_wad(sc)
    tc.setup_view_zp(sc, px, py, ab)
    sc._run(tc.ENTRY_BR_VIEW_SETUP)
    sc.init()
    sc.clear_screen()
    sc._run(0x481B)
    mpu = sc.mpu
    mem = mpu.memory
    mpu.pc = 0x4815
    mpu.sp = 0xFD
    mpu.p = 0x30
    mem[0x01FF] = 0xFE
    mem[0x01FE] = 0xFF
    mpu.processorCycles = 0
    buckets = {}
    prev_cyc = 0
    while mpu.pc != 0xFF00:
        i = bisect.bisect_right(addrs, mpu.pc) - 1
        name = names[i] if i >= 0 else '<low>'
        mpu.step()
        c = mpu.processorCycles
        buckets[name] = buckets.get(name, 0) + (c - prev_cyc)
        prev_cyc = c
    return buckets, mpu.processorCycles


if __name__ == '__main__':
    import sys
    addrs, names = build_symbols()
    if len(sys.argv) >= 4:
        POSITIONS = [(int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]))]
    else:
        POSITIONS = [(1056, -3616, 64), (1500, -3700, 0), (1024, -3500, 64)]

    total_buckets = {}
    totals = []
    for px, py, ab in POSITIONS:
        b, cyc = profile(px, py, ab, addrs, names)
        totals.append(((px, py, ab), cyc))
        for k, v in b.items():
            total_buckets[k] = total_buckets.get(k, 0) + v
    grand = sum(total_buckets.values())
    print(f'\n{"routine":34s} {"cycles":>10s} {"%":>6s}')
    for k, v in sorted(total_buckets.items(), key=lambda kv: -kv[1])[:32]:
        print(f'{k:34s} {v:10d} {100*v/grand:6.2f}')
    print()
    for pos, cyc in totals:
        print(f'{pos}: {cyc} cycles')
    print(f'total: {grand}')
