#!/usr/bin/env python3
"""Gate: the NJ blob's zero-page literals against what ld65 actually gave.

src/boot/linedraw_or.s is a SEPARATE ca65/ld65 unit -- it is not part of
the engine link -- and it names its thirteen zero-page bytes as LITERALS
(x0 = $82 .. y1 = $85, plus eight scratch).  The engine, meanwhile, lets
ld65 allocate RASTER_ZP_X0..Y1 and SCRSTRT wherever the zero page falls.
Nothing connected the two: they agree by luck, and a zp.inc edit that
moved RASTER_ZP_X0 would leave the rasteriser reading someone else's byte
with no build error and no test failure -- it would just draw wrong lines.
tools/layout_fuzz.py --sweep flagged exactly this (2026-09-05).

The blob cannot be generated from the map, because _build_raster() runs
BEFORE the engine links and symmap would recurse.  So this checks instead:

  1. the five ABI bytes equal ld65's allocation, and
  2. the eight SCRATCH bytes are occupied only by the engine variables
     recorded here as phase-disjoint.  zp.inc says of this range
     "nothing may live here across draws"; that is an invariant no build
     step enforces, so any NEW occupant fails this gate and has to be
     justified rather than discovered from a wrong picture.
"""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
os.chdir(ROOT)
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
import symmap

BLOB = os.path.join(ROOT, 'src', 'boot', 'linedraw_or.s')
ZPINC = os.path.join(ROOT, 'src', 'zp.inc')

# blob equate -> the engine symbol it must equal
ABI = {'scrstrt': 'RASTER_ZP_SCRSTRT', 'x0': 'RASTER_ZP_X0',
       'y0': 'RASTER_ZP_Y0', 'x1': 'RASTER_ZP_X1', 'y1': 'RASTER_ZP_Y1'}
SCRATCH = ('scr', 'cnt', 'err', 'errs', 'dx', 'dy', 'ls', 'b')

# Engine variables that KNOWINGLY share the rasteriser's scratch.  Each is
# phase-disjoint from a draw: the blob scribbles these bytes inside
# RASTER_ENTRY and nothing may hold a value across that call.
SHARERS = {'scr': {'zp_rc2_h'}, 'err': {'zp_rws_m'},
           # bca_boxp is a two-byte pointer at $86-$87, so it covers BOTH
           # the blob's ls and b.  Found by this gate on its first run.
           'ls': {'bca_boxp'}, 'b': {'bca_boxp'}}


def blob_equates():
    out = {}
    for line in open(BLOB):
        m = re.match(r'^(\w+)\s*=\s*\$([0-9A-Fa-f]+)\s*$', line.strip())
        if m:
            out[m.group(1)] = int(m.group(2), 16)
    return out


def zp_occupancy():
    """address -> {names} for every label declared in zp.inc's ZEROPAGE."""
    occ = {}
    tbl, _ = symmap._load(banked=1, c02=0)
    for line in open(ZPINC):
        m = re.match(r'^(\w+):\s*\.res\s+(\d+)', line)
        if not m:
            continue
        name, size = m.group(1), int(m.group(2))
        if name not in tbl:
            continue
        base = tbl[name]
        if base >= 0x100:
            continue
        for k in range(size):
            occ.setdefault(base + k, set()).add(name)
    return occ


def main():
    eq = blob_equates()
    occ = zp_occupancy()
    ok = True
    print('ABI bytes (blob literal vs ld65):')
    for k, sym in ABI.items():
        want = symmap.sym(sym, banked=1)
        good = eq.get(k) == want
        ok = ok and good
        print(f'   {k:8} ${eq.get(k, -1):02X}  {sym:20} ${want:02X}  '
              f'{"ok" if good else "*** MISMATCH ***"}')
    print('scratch bytes (who else is there):')
    for k in SCRATCH:
        a = eq[k]
        here = occ.get(a, set())
        allowed = SHARERS.get(k, set())
        extra = here - allowed
        ok = ok and not extra
        note = ('clear' if not here else ', '.join(sorted(here)))
        print(f'   {k:8} ${a:02X}  {note:28}'
              + (f'  *** UNEXPECTED: {", ".join(sorted(extra))} ***' if extra
                 else '  ok'))
    dup = [a for a in set(eq.values()) if list(eq.values()).count(a) > 1]
    if dup:
        ok = False
        print(f'   *** two blob equates share {["$%02X" % a for a in dup]} ***')
    print('RASTERZP: ' + ('PASS' if ok else 'FAIL'))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
