#!/usr/bin/env python3
"""Object template/ladder contract gate (2026-09-03, rebuilt after the
potion-crash hunt).  For EVERY billboard kind and EVERY tier the engine
can actually select (enumerated from obj_lodh / obj_tpl_off2 — the
2026-09-03 potion crash lived exactly in a (template, tier) combo a
hand-kept list never drove), run the kind's ladder builder over a size
sweep and check, against the BUILT art blob:

  1. POISON: no template line reads an obj_X/obj_Y slot the builder (or
     the prologue's 0/10 seed) did not write — the vest full-width line
     and the potion far-ladder crash were both stale-slot reads.
  2. X ORDER: every line resolves xl <= xr — the clipper's ordering
     contract is caller-owned; a reversed HORIZONTAL wraps plot_h's
     byte-strip walk (the escaping-lines repro).
  3. VERTICAL Y ORDER: xl == xr lines resolve yl <= yr — vplot's
     armed-RTS unroll REQUIRES Y0 <= Y1 (a violation runs off the
     unroll: the (585,-3437,244) crash).
  (Run-level authority monotonicity is NOT checked: the fused walker
  clips each armed line INDEPENDENTLY — the lamp's interleaved authority
  run has always been non-monotonic and correct.  The 2026-09-03
  "cursor" theory was wrong; per-LINE order is the whole contract.)
"""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
import doom_wireframe as dw
from banked_bsp import BankedBspRender, BANK_C
from symmap import sym

# kind -> ladder builder entry (obj_sel_hex is inline in the dispatch and
# the hex/oct pair predates the slot ladder; the five table-driven
# builders below are the stale-slot surface)
BUILDERS = {1: 'obj_lamp_xy', 2: 'obj_potion_xy', 3: 'obj_helmet_xy',
            4: 'obj_box_y', 5: 'obj_box_y', 6: 'obj_vest_xy'}
KTAB = [23, 15, 25, 34, 30, 47, 58]
POISON = 0x7F7F                 # s16 32639 — no legit screen coord
SENT = POISON - 0x10000 + 0x10000  # comparison value as unsigned pair


def main():
    r = BankedBspRender(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                        dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y,
                        dw.PRESCALE)
    sc = r.sc; mem = sc.mpu.memory
    OX = sym('obj_X', banked=1)
    OY = sym('obj_Y', banked=1)
    assert OY == OX + 12, 'obj_Y must abut obj_X'

    L = dw.packed_layout
    art = dw.packed_rom_main[L['off_obj_art']:L['off_obj_art'] + L['art_len']]

    # the engine's own selection tables, from the built bank C image
    save = mem[0xFE30]; mem.select(BANK_C)
    lodh = [mem[sym('obj_lodh', banked=1) + k] for k in range(7)]
    tpl_pg = [mem[sym('obj_tpl_pg2', banked=1) + i] for i in range(14)]
    tpl_off = [mem[sym('obj_tpl_off2', banked=1) + i] for i in range(14)]
    mem.select(save)
    art_pg = sym('OBJ_ART', banked=1) >> 8

    def template(kind, tier):
        win = (tpl_pg[kind * 2 + tier] - art_pg) << 8
        off = tpl_off[kind * 2 + tier]
        out, armed = [], False
        e = win + off
        while True:
            a, b, c, d = art[e:e + 4]
            if a == 0xFF:
                break
            if a == 0xFE:
                armed = True
            else:
                out.append(((a, b, c, d), armed))
            e += 4
        return out

    def s16(base, o):
        v = mem[base + o] | (mem[base + o + 1] << 8)
        return v - 0x10000 if v >= 0x8000 else v

    ok = True
    cases = []

    def fail(tag, msg):
        nonlocal ok
        ok = False
        print(f'  {tag}: {msg}')

    for kind, builder in sorted(BUILDERS.items()):
        tiers = [0] if lodh[kind] == 0xFF else [0, 1]
        for tier in tiers:
            if lodh[kind] == 0xFF:
                sizes = [4, 12, 60, 200]
            elif tier == 0:
                sizes = [4, max(4, lodh[kind] - 1)]
            else:
                sizes = [lodh[kind], 60, 200]
            lines = template(kind, tier)
            for H in sizes:
                cx, syt = 400, 40
                a = (H * KTAB[kind] + 32) >> 6
                # poison EVERYTHING, then seed exactly what the stamp
                # prologue seeds (slots 0/10 = cx -+ a)
                for o in range(0, 64, 2):
                    mem[OX + o] = POISON & 0xFF
                    mem[OX + o + 1] = POISON >> 8
                mem[sym('obj_h', banked=1)] = H
                mem[sym('obj_a', banked=1)] = a
                mem[sym('obj_asp', banked=1)] = kind
                mem[sym('obj_lod', banked=1)] = tier
                mem[sym('obj_cx_l', banked=1)] = cx & 0xFF
                mem[sym('obj_cx_h', banked=1)] = (cx >> 8) & 0xFF
                mem[sym('obj_yt_l', banked=1)] = syt & 0xFF
                mem[sym('obj_yt_h', banked=1)] = 0
                mem[sym('obj_yb_l', banked=1)] = (syt + H) & 0xFF
                mem[sym('obj_yb_h', banked=1)] = ((syt + H) >> 8) & 0xFF
                for o, v in ((0, cx - a), (10, cx + a)):
                    mem[OX + o] = v & 0xFF
                    mem[OX + o + 1] = (v >> 8) & 0xFF
                mem[0xFE30] = BANK_C
                sc._run(sym(builder, banked=1))
                tag = f'kind{kind} T{tier} H={H}'
                tier_bad = 0
                for (xa, ya, xb, yb), armed in lines:
                    x0, x1 = s16(OX, xa), s16(OX, xb)
                    y0, y1 = s16(OY, ya), s16(OY, yb)
                    pois = [f'obj_{b}+{o}' for v, b, o in
                            ((x0, 'X', xa), (x1, 'X', xb),
                             (y0, 'Y', ya), (y1, 'Y', yb))
                            if v in (POISON, POISON - 0x10000)]
                    if pois:
                        fail(tag, f'line {(xa,ya,xb,yb)}: UNWRITTEN slot(s) '
                                  f'{pois} (poison read)')
                        tier_bad += 1
                    if x0 > x1:
                        fail(tag, f'line {(xa,ya,xb,yb)}: x REVERSED '
                                  f'({x0}->{x1}) — plot_h wraps')
                        tier_bad += 1
                    # y order is checked for AUTHORED verticals only: a
                    # diagonal that COLLAPSES to one column at tiny sizes
                    # goes through dcl_vertical's swap arm (probed exact,
                    # in- and out-of-band, 2026-09-03) — reversal there
                    # is the engine's to normalize, not the art's.
                    if xa == xb and y0 > y1:
                        fail(tag, f'line {(xa,ya,xb,yb)}: authored vertical '
                                  f'y REVERSED ({y0}->{y1})')
                        tier_bad += 1
                cases.append((f'kind{kind} T{tier}', tier_bad))
            n_bad = sum(b for t, b in cases if t == f'kind{kind} T{tier}')
            print(f'  kind{kind} T{tier}: {len(lines)} lines x '
                  f'H={sizes}: ' + ('OK' if not n_bad else f'{n_bad} FAILURES'))
    print('AUTHMONO:', 'PASS' if ok else 'FAIL')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
