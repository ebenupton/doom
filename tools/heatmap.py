#!/usr/bin/env python3
"""Per-source-line cycle heat, annotated straight into the .s file.

    python3 tools/heatmap.py src/clip/tfr.s [--pos X,Y,ANG] [--strip]

Runs one frame under py65, buckets every cycle by PC, maps PC to source
line through the ld65 debug file's line/span records (exact — no listing
guesswork), and rewrites the file with a bar chart in a trailing comment
on each line that executed:

       LDA POOL_XEND,Y                     ;#| ||||||||  1.8%

The bar is log-scaled: a linear bar spends its whole range on the single
hottest loop and shows nothing anywhere else.  Marker is `;#|` so the
annotations can be stripped again with --strip.
"""
import os, re, sys, subprocess

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
MARK = ';#|'
WIDTH = 8
COL = 74


def parse_dbg(path, want):
    """-> {addr: line} for the wanted source file.

    TWO passes: ld65 emits the `line` records BEFORE the `seg` and
    `span` records they refer to, so a single pass sees empty tables and
    silently maps nothing."""
    raw = open(path).readlines()

    def fields(rest):
        return dict(re.findall(r'(\w+)=("?[^,"]*"?)', rest))

    segs, spans, fid = {}, {}, None
    for ln in raw:
        k, _, rest = ln.partition('\t')
        if k == 'file':
            d = fields(rest)
            if d.get('name', '').strip('"').endswith(want):
                fid = d['id']
        elif k == 'seg':
            d = fields(rest)
            segs[d['id']] = int(d['start'], 0)
        elif k == 'span':
            d = fields(rest)
            spans[d['id']] = (d['seg'], int(d['start']), int(d['size']))
    if fid is None:
        return {}

    lines = {}
    for ln in raw:
        k, _, rest = ln.partition('\t')
        if k != 'line':
            continue
        d = fields(rest)
        if d.get('file') != fid:
            continue
        for sid in re.findall(r'span=([\d+]+)', rest):
            for sp in sid.split('+'):
                if sp not in spans:
                    continue
                sg, st, sz = spans[sp]
                base = segs.get(sg)
                if base is None:
                    continue
                for a in range(base + st, base + st + sz):
                    lines[a] = int(d['line'])
    return lines


def run_frame(px, py, ab):
    os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
    os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
    sys.path.insert(0, ROOT)
    import pygame; pygame.init(); pygame.display.set_mode((1, 1))
    import doom_wireframe as dw, trace_compare as tc
    from symmap import sym
    _ = dw.Instrumented6502Spans(); sc = dw._span_clip_6502
    tc.setup_wad(sc); tc.setup_view_zp(sc, px, py, ab)
    sc._run(tc.ENTRY_BR_VIEW_SETUP); sc.init(); sc.clear_screen()
    from bsp_render_6502 import poke_init_frame_state
    poke_init_frame_state(sc.mpu.memory)
    mpu = sc.mpu; mem = mpu.memory
    mpu.pc = sym('render_frame'); mpu.sp = 0xDD; mpu.p = 0x30
    mem[0x01DF] = 0xFE; mem[0x01DE] = 0xFF; mpu.processorCycles = 0
    hot = {}; prev = 0
    while mpu.pc != 0xFF00:
        pc = mpu.pc
        mpu.step()
        c = mpu.processorCycles
        hot[pc] = hot.get(pc, 0) + c - prev
        prev = c
    return hot, mpu.processorCycles


def strip(path):
    out = []
    for ln in open(path):
        i = ln.find(MARK)
        out.append((ln[:i].rstrip() + '\n') if i >= 0 else ln)
    open(path, 'w').writelines(out)


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else 'src/clip/tfr.s'
    path = os.path.join(ROOT, src)
    strip(path)                       # always re-annotate from clean
    if '--strip' in sys.argv:
        print(f'stripped {src}')
        return
    pos = (1133, -3242, 0x90)
    for a in sys.argv[2:]:
        if a.startswith('--pos'):
            pos = tuple(int(x, 0) for x in a.split('=', 1)[1].split(','))

    import importlib
    sys.path.insert(0, ROOT)
    import asmbuild; asmbuild.build_all(banked=0, force=True)
    # the LINKED debug file: the per-object ones carry start=0 segments
    dbg = os.path.join(ROOT, 'build', 'engine_b0c0.dbg')
    amap = parse_dbg(dbg, os.path.basename(src))
    hot, total = run_frame(*pos)

    per = {}
    for pc, c in hot.items():
        ln = amap.get(pc)
        if ln:
            per[ln] = per.get(ln, 0) + c
    if not per:
        print(f'no executed lines mapped for {src}'); return
    peak = max(per.values())
    body = sum(per.values())
    lines = open(path).readlines()
    # Percentages are of THIS FILE's own total, not the frame: tfr is 11%
    # of the frame spread over 500 lines, so frame-relative numbers are
    # all 0.0% and say nothing.  The bar is sqrt-scaled — linear spends
    # its whole range on the peak, log flattens everything to the same
    # height, and the data here has no single dominant line.
    for ln, c in per.items():
        if ln - 1 >= len(lines):
            continue
        raw = lines[ln - 1].rstrip('\n')
        if not raw.strip() or raw.lstrip().startswith(';'):
            continue
        n = max(1, round(WIDTH * (c / peak) ** 0.5))
        pct = 100.0 * c / body
        pad = max(1, COL - len(raw))
        lines[ln - 1] = (f'{raw}{" " * pad}{MARK}{"|" * n:<{WIDTH}}'
                         f'{pct:4.1f}\n')
    open(path, 'w').writelines(lines)
    print(f'{src}: {len(per)} executed lines, {body:,} of {total:,} frame '
          f'cycles ({100.0*body/total:.1f}%)\n')
    print(f'  hottest lines (% of the file\'s {body:,} cycles):')
    for ln, c in sorted(per.items(), key=lambda kv: -kv[1])[:12]:
        txt = lines[ln - 1].split(MARK)[0].strip()
        print(f'    {ln:5d}  {100.0*c/body:5.2f}%  {c:6,}  {txt[:52]}')


main()
