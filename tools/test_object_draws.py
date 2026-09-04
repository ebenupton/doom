#!/usr/bin/env python3
"""Do the billboards actually get drawn?

THE HOLE THIS CLOSES: on 2026-08-31 a routine landed in the middle of the
object builder's fall-through, so every object overwrote its own y ladder and
returned early -- billboards stopped drawing ALTOGETHER -- and the whole
suite stayed green.  The pixel comparisons do not cover billboards, so
nothing else in the gate can see this class of failure.

Count the art stamps over the render corpus and check the total and the
per-template split.
"""
import os, sys, collections
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT); sys.path.insert(0, os.path.join(ROOT, 'tools'))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init()
import doom_wireframe as dw, compare_renders as C
from banked_bsp import BankedBspRender
from symmap import sym

# Counted per template start, named by the KIND byte.  The pickup landing
# (2026-08-31) put 44 more billboards in the map; EXPECT is the measured
# corpus census -- any drop is a lost draw.  LAMP fell 11 -> 8 when the
# candelabras were removed outright (they had borrowed the template and
# accounted for three of the corpus's stamps).
EXPECT = {'HEX': 9, 'LAMP': 6,
          'POTION': 7, 'HELMET': 25, 'BOXS': 1, 'BOXM': 2, 'VEST': 1}
# (POTION 9 -> 7, 2026-09-01: the armour-room strip removed the only two
#  zigzag-room potions the corpus ever had in view; the room's helmets
#  never stamped from the corpus positions, so HELMET holds at 23.)
# (HELMET 23 -> 25, 2026-09-04: the near-child bbox test was dropped from
#  the walk -- DOOM's shape, see bsp/walk.s -- so the traversal now enters
#  subsectors it used to cull, and two more helmet billboards get STAMPED.
#  They draw nothing: the framebuffer is byte-identical at all 29
#  fingerprint poses and the slot-coverage guard below still passes, so
#  this is stamping work the fully-occluded early-out discards, not new
#  geometry.  A DROP below these numbers is still a lost draw.)
# (LAMP 8 -> 6, 2026-09-03: the two spawn-hall lamps by the armour-room
#  approach were removed; the two new lamps at the step opening east of
#  the courtyard are outside every corpus view.  The two approach
#  hoplites removed the same day were never in a corpus view either.)

def main():
    r = BankedBspRender(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                        dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y,
                        dw.PRESCALE)
    mpu = r.sc.mpu; mem = mpu.memory
    entry = sym('render_frame', banked=1)
    STAMP = sym('obj_stamp', banked=1)
    OE = sym('obj_e', banked=1)
    OASP = sym('obj_asp', banked=1)
    OA_RD0 = sym('oa_rd0', banked=1)      # +2 = the art WINDOW high byte (SMC)
    KINDS = ('HEX','LAMP','POTION','HELMET','BOXS','BOXM','VEST')
    # A template start is a (WINDOW high byte, offset) pair, read from the
    # engine's own tier tables (2026-09-03): offsets are bytes within a
    # 256-B window, so HELM_L0's END control (window A, +224) has the same
    # low byte as HELM_L1's start (window C, +224) -- keyed on the offset
    # alone a near-tier helmet counted twice.
    # The tables live in bank C (VPTAB in the VPLOTC region), so read them
    # from that bank's image rather than through the paged window.
    BANK_C = sym('BANK_C', banked=1)
    _bc = mem._banks[BANK_C]
    PG2 = sym('obj_tpl_pg2', banked=1) - 0x8000
    OFF2 = sym('obj_tpl_off2', banked=1) - 0x8000
    TPL_START = tuple({(_bc[PG2 + 2 * k + t], _bc[OFF2 + 2 * k + t]) for t in (0, 1)}
                      for k in range(len(KINDS)))
    assert all(TPL_START), f'empty template-start table: {TPL_START}'
    n = collections.Counter()
    for (px, py, ab) in C.POSITIONS:
        last = [None]                       # per pose: a key must not carry over
        r.render_frame(px, py, ab, dw.player_floor(px, py))
        r.sc.init(); r.sc.clear_screen()
        mpu.pc = entry; mpu.sp = 0xDD; mpu.p = 0x30
        mem[0x01DF] = 0xFE; mem[0x01DE] = 0xFF
        k = 0
        while mpu.pc != 0xFF00 and k < 3_000_000:
            # obj_e ADVANCES through the template, so only count the first
            # entry of each object -- and only when it is a template start.
            # KEY ON THE WINDOW TOO (2026-09-03): offsets are bytes within a
            # 256-B window, so HELM_L0's END control (window A, +224) has
            # the same low byte as HELM_L1's start (window C, +224); keyed
            # on e alone a near-tier helmet counted twice.
            if mpu.pc == STAMP:
                e = mem[OE]; kind = mem[OASP]
                key = (kind, mem[OA_RD0 + 2], e)
                if key[1:] in TPL_START[kind] and key != last[0]:
                    n[KINDS[kind]] += 1
                last[0] = key
            mpu.step(); k += 1
    got = dict(n)
    print(f'  stamps: {got}  (expect {EXPECT})')
    ok = got == EXPECT

    # SLOT-COVERAGE GUARD (2026-09-03): an art template that references a
    # generator-UNWRITTEN ladder slot draws an authority line from a
    # garbage x (usually 0 = the screen edge) -- the vest's missing
    # corner magnitude (slots 58/60) swept a full-width line across the
    # armour room.  No object line may span more than a billboard's
    # width; a garbage-slot line runs edge-to-edge.  Object-only lines =
    # (objects-on) minus (objects-off) per pose.
    from bsp_render_6502 import disable_objects
    LIM = 140                         # px; the widest legit near-LOD art
    worst = 0; wpose = None
    for (px, py, ab) in C.POSITIONS:
        # objects were seeded on at construction; render on, then off
        r.render_frame(px, py, ab, dw.player_floor(px, py))
        onl = set(r.sc.last_lines)
        disable_objects(mem)
        r.render_frame(px, py, ab, dw.player_floor(px, py))
        offl = set(r.sc.last_lines)
        # reseed objects for the next pose
        _bits = dw.packed_layout['off_obj'] + 7 * dw.packed_layout['n_obj']
        _anyb = sym('OBJ_ANYB', banked=1)
        for i in range(dw.packed_layout['obj_bits_len']):
            mem[_anyb + i] = dw.packed_rom_main[_bits + i]
        # A billboard TIGHTENS behind itself, so a wall line drawn after
        # it comes out a few columns shorter than in the objects-off frame:
        # that re-fragment is not an object line.  Discount any on-only
        # line whose endpoints both lie on (within 1px of) some off-frame
        # line; what survives is art, or a garbage slot.
        def _on_seg(pt, seg):
            (x, y), (ax, ay, bx, by) = pt, seg
            dx, dy = bx - ax, by - ay
            L2 = dx * dx + dy * dy
            t = 0 if L2 == 0 else max(0, min(1, ((x - ax) * dx + (y - ay) * dy) / L2))
            return (x - ax - t * dx) ** 2 + (y - ay - t * dy) ** 2 <= 1.0
        for (x0, y0, x1, y1) in onl - offl:
            if any(_on_seg((x0, y0), w) and _on_seg((x1, y1), w) for w in offl):
                continue                            # wall re-fragment
            span = max(abs(x0 - x1), abs(y0 - y1))
            if span > worst:
                worst = span; wpose = (px, py, ab, x0, y0, x1, y1)
    print(f'  widest object-only line span: {worst}px (limit {LIM})')
    if worst > LIM:
        ok = False
        print(f'    RUNAWAY LINE at {wpose[:3]}: ({wpose[3]},{wpose[4]})-'
              f'({wpose[5]},{wpose[6]}) -- an art slot is unwritten')

    print('OBJDRAWS:', 'PASS' if ok else f'FAIL (got {got}, expect {EXPECT})')
    return 0 if ok else 1

if __name__ == '__main__':
    sys.exit(main())
