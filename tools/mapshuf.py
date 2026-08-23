#!/usr/bin/env python3
"""mapshuf — mechanical address-map occupancy for BOTH builds.

    python3 tools/mapshuf.py                 free runs, flat + banked + shared
    python3 tools/mapshuf.py --need 96       runs that fit N bytes in BOTH
    python3 tools/mapshuf.py --bank 4        detail one sideways bank

WHY THIS EXISTS.  Free space has been tracked in source comments, per
build, by hand.  That has cost real time twice: the $64 trap (a "free"
note that was only free in one build), and the $1100 page nobody
remembered was free.  The comments also cannot see the difference
between "no segment claims it" and "nothing ever touches it" -- and the
second is what actually matters when you want to put something there.

METHOD.  Two independent sources, intersected:
  1. CLAIMED -- the ld65 map files' segment extents.  Authoritative for
     code and initialised data.
  2. TOUCHED -- every address the CPU reads or writes across the
     19-position corpus, captured by wrapping the memory object.  This
     catches runtime arenas that no segment declares: pools, records,
     caches, the span structures.  Window accesses ($8000-$BFFF) are
     attributed to the bank paged at the time, read from
     BankedMemory._cur.

FREE = neither claimed nor touched.  A run free in ONE build is a trap;
only the intersection is safe, which is why that is the headline.

CAVEAT: touched-ness is only as good as the corpus.  A run this tool
calls free is free FOR THE PATHS THE CORPUS EXERCISES.  Boot-time and
respawn code is not in a rendered frame -- check those by hand before
claiming a run.
"""
import os, re, sys, collections
ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
sys.path.insert(0, ROOT); sys.path.insert(0, os.path.join(ROOT, 'tools'))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

WINDOW_LO, WINDOW_HI = 0x8000, 0xC000


class Probe:
    """Memory proxy that records every address touched, by bank."""

    def __init__(self, inner, banked):
        self._m = inner
        self._banked = banked
        self.main = bytearray(0x10000)          # 1 = touched
        self.bank = collections.defaultdict(lambda: bytearray(0x4000))

    def _mark(self, a):
        if self._banked and WINDOW_LO <= a < WINDOW_HI:
            cur = getattr(self._m, '_cur', None)
            if cur is not None:
                self.bank[cur][a - WINDOW_LO] = 1
                return
        self.main[a] = 1

    def __getitem__(self, i):
        if isinstance(i, slice):
            return self._m[i]
        self._mark(i)
        return self._m[i]

    def __setitem__(self, i, v):
        if isinstance(i, slice):
            self._m[i] = v
            return
        self._mark(i)
        self._m[i] = v

    def __len__(self):
        return len(self._m)

    def __getattr__(self, n):
        return getattr(self._m, n)


def segments(mapfile):
    """-> [(name, start, end_exclusive)] from an ld65 map."""
    out, on = [], False
    for ln in open(os.path.join(ROOT, 'build', mapfile)):
        if ln.startswith('Segment list'):
            on = True; continue
        if on:
            if ln.startswith('Exports') or ln.startswith('Modules'):
                break
            m = re.match(r'^(\w+)\s+([0-9A-F]{6})\s+([0-9A-F]{6})\s+([0-9A-F]{6})', ln)
            if m:
                nm, st, _en, sz = m.group(1), int(m.group(2), 16), 0, int(m.group(4), 16)
                if sz:
                    out.append((nm, st, st + sz))
    return out


def regions(cfg):
    """-> [(name, start, size)] from an ld65 cfg MEMORY block."""
    out, on = [], False
    for ln in open(os.path.join(ROOT, 'src', cfg)):
        t = ln.split('#')[0]
        if 'MEMORY' in t and '{' in t:
            on = True; continue
        if on:
            if '}' in t:
                break
            m = re.match(r'\s*(\w+):\s*start\s*=\s*\$([0-9A-Fa-f]+),\s*size\s*=\s*\$([0-9A-Fa-f]+)', t)
            if m:
                out.append((m.group(1), int(m.group(2), 16), int(m.group(3), 16)))
    return out


def region_report(tag, cfg, mapfile):
    """Region budget: how much of each linker region the segments use."""
    regs = regions(cfg)
    segs = segments(mapfile)
    print(f'\n{tag} LINKER REGIONS (cfg budget vs segments placed)')
    for nm, st, sz in regs:
        inside = [(n, a, b) for n, a, b in segs if a >= st and b <= st + sz]
        if not inside:
            continue
        top = max(b for _n, _a, b in inside)
        used = top - st
        print(f'   {nm:8s} ${st:04X}+{sz:<6d} used {used:6d}  FREE {sz-used:6d}'
              f'  (tail ${top:04X}-${st+sz-1:04X})')


def runs(free, lo, hi, minlen):
    """-> [(start, length)] maximal runs of free[] set, within [lo,hi)."""
    out, s = [], None
    for a in range(lo, hi + 1):
        f = a < hi and free[a]
        if f and s is None:
            s = a
        elif not f and s is not None:
            if a - s >= minlen:
                out.append((s, a - s))
            s = None
    return out


def build_free(touched_main, segs, lo, hi):
    free = bytearray(0x10000)
    for a in range(lo, hi):
        free[a] = 1
    for _nm, st, en in segs:
        for a in range(max(st, lo), min(en, hi)):
            free[a] = 0
    for a in range(lo, hi):
        if touched_main[a]:
            free[a] = 0
    return free


def run_corpus(banked):
    import doom_wireframe as dw
    import compare_renders as C
    if banked:
        from banked_bsp import BankedBspRender
        r = BankedBspRender(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                            dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y,
                            dw.PRESCALE)
        inner = r.bm
    else:
        from bsp_render_6502 import BspRender6502
        r = BspRender6502(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                          dw.packed_bbox_table)
        inner = r.sc.mpu.memory
    p = Probe(inner, banked)
    r.sc.mpu.memory = p
    if banked:
        r.bm = p
    for (px, py, ab) in C.POSITIONS:
        r.render_frame(px, py, ab, dw.player_floor(px, py))
    return p


def main():
    need = 0; want_bank = None
    for a in sys.argv[1:]:
        if a.startswith('--need'):
            need = int(a.split('=', 1)[1] if '=' in a else sys.argv[sys.argv.index(a) + 1])
        if a.startswith('--bank'):
            want_bank = int(a.split('=', 1)[1] if '=' in a else sys.argv[sys.argv.index(a) + 1])
    minlen = max(need, 16)

    region_report('FLAT', 'engine_flat.cfg', 'engine_b0c0.map')
    region_report('BANKED', 'engine_banked.cfg', 'engine_b1c0.map')

    flat_segs = segments('engine_b0c0.map')
    bank_segs = segments('engine_b1c0.map')
    pf = run_corpus(False)
    pb = run_corpus(True)

    # main RAM below the window is the SHARED map (identical in both builds)
    ff = build_free(pf.main, flat_segs, 0x0000, WINDOW_LO)
    fb = build_free(pb.main, bank_segs, 0x0000, WINDOW_LO)
    shared = bytearray(a and b for a, b in zip(ff, fb))

    print(f'\nSHARED main RAM $0000-$7FFF  (free in BOTH builds, runs >= {minlen} B)')
    tot = 0
    for st, n in runs(shared, 0x0000, WINDOW_LO, minlen):
        print(f'   ${st:04X}-${st+n-1:04X}   {n:5d} B')
        tot += n
    print(f'   {"":21s}{tot:5d} B total')

    for tag, free in (('FLAT only', ff), ('BANKED only', fb)):
        extra = [(s, n) for s, n in runs(free, 0, WINDOW_LO, minlen)
                 if not all(shared[s:s + n])]
        if extra:
            print(f'\n{tag} main RAM (NOT free in the other build -- a trap):')
            for st, n in extra:
                print(f'   ${st:04X}-${st+n-1:04X}   {n:5d} B')

    print(f'\nFLAT $8000-$FFFF')
    ffh = build_free(pf.main, flat_segs, WINDOW_LO, 0x10000)
    for st, n in runs(ffh, WINDOW_LO, 0x10000, minlen):
        print(f'   ${st:04X}-${st+n-1:04X}   {n:5d} B')

    print(f'\nBANKED sideways banks (window $8000-$BFFF)')
    for bk in sorted(pb.bank):
        if want_bank is not None and bk != want_bank:
            continue
        t = bytearray(0x10000)
        for i, v in enumerate(pb.bank[bk]):
            t[WINDOW_LO + i] = v
        fr = build_free(t, [], WINDOW_LO, WINDOW_HI)
        rs = runs(fr, WINDOW_LO, WINDOW_HI, minlen)
        print(f'   bank {bk}: ' + (', '.join(f'${s:04X}+{n}' for s, n in rs) or 'full'))

    if need:
        print(f'\n--need {need}: shared runs that fit')
        hit = [(s, n) for s, n in runs(shared, 0, WINDOW_LO, need)]
        for st, n in hit:
            print(f'   ${st:04X}-${st+n-1:04X}   {n:5d} B')
        if not hit:
            print('   none in shared main RAM')


if __name__ == '__main__':
    main()
