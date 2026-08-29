"""Bank-paging census for the BANKED build: who pays the switching cost.

The banked build is the reference (2026-08-29), and its whole cost delta
over the flat one is paging: +697 cycles/frame on the 18-pose suite.  This
counts every ROMSEL write a frame makes, splits them into REAL switches
(the bank actually changed) and NO-OP re-selects (the bank was already
live -- 4 wasted cycles each, an LDA+STA that did nothing), and attributes
both to the PC that stored.

    python3 tools/pagecensus.py            # the compare_renders suite
    python3 tools/pagecensus.py 1500 -3700 0

Read the NO-OP column first: those are pure waste, removable without any
restructuring, and each is worth 4 cycles (LDA #imm + STA abs = 2+4, less
the 2 the load would cost anyway) every time it executes.
"""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init()
import doom_wireframe as dw
from banked_bsp import BankedBspRender
import banked_mem, symmap

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')


def line_map():
    """PC -> 'file:line', for every source file, off the BANKED debug map.

    Reuses heatmap's two-pass parser: ld65 emits `line` records BEFORE the
    `seg`/`span` records they refer to, so a single pass maps nothing.
    """
    sys.path.insert(0, os.path.join(ROOT, 'tools'))
    import heatmap as H, glob
    dbg = os.path.join(ROOT, 'build', 'engine_b1c0.dbg')
    out = {}
    if not os.path.exists(dbg):
        return out
    srcs = set()
    for ln in open(dbg):
        if ln.startswith('file\t'):
            import re as _re
            m = _re.search(r'name="([^"]+)"', ln)
            if m:
                srcs.add(os.path.basename(m.group(1)))
    for base in srcs:
        for pc, lno in H.parse_dbg(dbg, base).items():
            out.setdefault(pc, f'{base}:{lno}')
    return out


_RIG = None


def rig():
    global _RIG
    if _RIG is None:
        _RIG = BankedBspRender(dw.packed_layout, dw.packed_rom_main,
                               dw.packed_rom_detail, dw.packed_bbox_table,
                               dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    return _RIG


def census(px, py, ab, amap):
    r = rig()
    bm, mpu = r.bm, r.sc.mpu
    real, noop = {}, {}
    ROMSEL = banked_mem.ROMSEL
    orig = type(bm).__setitem__

    def watch(self, k, v):
        if k == ROMSEL:
            # py65 has already advanced PC past the 3-byte STA abs by the
            # time the write lands, so the store site is pc-3.
            pc = (mpu.pc - 3) & 0xFFFF
            d = noop if v == self._cur else real
            d[pc] = d.get(pc, 0) + 1
        return orig(self, k, v)
    type(bm).__setitem__ = watch
    try:
        r.render_frame(px, py, ab, dw.player_floor(px, py))
    finally:
        type(bm).__setitem__ = orig
    return real, noop, r


def main():
    amap = line_map()
    poses = [(1500, -3700, 0)]
    if len(sys.argv) == 4:
        poses = [(float(sys.argv[1]), float(sys.argv[2]), int(sys.argv[3]))]
    elif len(sys.argv) > 1 and sys.argv[1] == '--suite':
        import compare_renders as C
        poses = C.POSITIONS
    tr = tn = 0
    agg_r, agg_n = {}, {}
    for (px, py, ab) in poses:
        real, noop, r = census(px, py, ab, amap)
        sr, sn = sum(real.values()), sum(noop.values())
        tr += sr; tn += sn
        for d, agg in ((real, agg_r), (noop, agg_n)):
            for pc, c in d.items():
                agg[pc] = agg.get(pc, 0) + c
        print(f'  ({px},{py},{ab}): {sr:5d} real switches  {sn:5d} no-op re-selects')
    n = len(poses)
    print(f'\nMEAN per frame: {tr/n:.1f} real, {tn/n:.1f} no-op '
          f'(no-op waste ~{4*tn/n:.0f} cyc/frame)')
    for title, agg in (('REAL switches', agg_r), ('NO-OP re-selects', agg_n)):
        print(f'\n== {title} by store site ==')
        for pc, c in sorted(agg.items(), key=lambda kv: -kv[1])[:15]:
            print(f'  &{pc:04X} {amap.get(pc, "?"):32s} {c/n:8.1f}/frame')


if __name__ == '__main__':
    main()
