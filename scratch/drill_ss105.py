#!/usr/bin/env python3
"""Drill the ss=105 over-traversal violation at (973,-3367,239):
reproduce the reject-only walk, capture every clips call made during the
violating subsector, and dump each seg's transform pipeline stages."""
import os
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw
import fp
from fp import PRESCALE, MAP_CENTER_X as MCX, MAP_CENTER_Y as MCY, NEAR_FP, fp_to_view, fp_recip, fp_project_x, m8
from wad_packed import (read_u8, read_u16, read_s16, SEG_HDR_SIZE, SH_V1, SH_V2,
                        SH_LV1X, SH_LV1Y, SH_LDX, SH_LDY, SH_FLAGS)
from overtraversal_probe import setup, reject_only, corner_visits

PX, PY, AB, SS = 973, -3367, 239, 105

corner = corner_visits(PX, PY, AB)
assert SS not in corner
ctx, vz, cf, sf, ram = setup(PX, PY, AB)
clips = dw.Instrumented6502Spans()
surf = pygame.Surface((dw.FP_RENDER_W, dw.FP_RENDER_H))

# subsector's segs from the packed ROM
rom = dw.packed_rom_main
lay = dw.packed_layout
ss_off = lay['off_ss'] + SS * 4
count = read_u8(rom, ss_off)
first = read_u16(rom, ss_off + 2)
print(f"ss={SS}: {count} segs from {first}")
for si in range(first, first + count):
    h = lay['off_seg_hdr'] + (si - 0) * SEG_HDR_SIZE
    v1 = read_u16(rom, h + SH_V1); v2 = read_u16(rom, h + SH_V2)
    fl = read_u8(rom, h + SH_FLAGS)
    voff = lay['off_verts']
    wx1 = read_s16(rom, voff + v1 * 4); wy1 = read_s16(rom, voff + v1 * 4 + 2)
    wx2 = read_s16(rom, voff + v2 * 4); wy2 = read_s16(rom, voff + v2 * 4 + 2)
    _, evx1, evy1, _, eyi1 = fp_to_view(wx1, wy1, ctx)
    _, evx2, evy2, _, eyi2 = fp_to_view(wx2, wy2, ctx)
    def px_of(evx, evy, eyi):
        if evy < NEAR_FP:
            return 'BEHIND'
        rh, rl = fp_recip(eyi)
        return fp_project_x(evx, rh, rl)
    print(f"  seg {si}: v1={v1}@({wx1},{wy1}) v2={v2}@({wx2},{wy2}) flags={fl:02X}")
    print(f"    view: v1 evx={evx1} evy={evy1} -> sx={px_of(evx1,evy1,eyi1)}   "
          f"v2 evx={evx2} evy={evy2} -> sx={px_of(evx2,evy2,eyi2)}")
    if (evy1 < NEAR_FP) != (evy2 < NEAR_FP):
        dvy = evy2 - evy1
        t = ((NEAR_FP - evy1) << 8) // dvy
        dvx = evx2 - evx1
        cx = evx1 + m8(t, dvx)
        rh, rl = fp_recip(NEAR_FP << 1)
        print(f"    CROSSING: t={t} dvx={dvx} cx={cx} -> sx={fp_project_x(cx, rh, rl)}")

# replay walk, capture clips calls during SS
calls = []
orig_ss = dw.packed_render_subsector
orig_bbox = dw.fp_bbox_visible_fixed
in_target = [False]

class Tap(dw.Instrumented6502Spans):
    def mark_solid(self, lo, hi):
        if in_target[0]: calls.append(('mark_solid', lo, hi))
        return super().mark_solid(lo, hi)
    def tighten(self, lo, hi, *a, **k):
        if in_target[0]: calls.append(('tighten', lo, hi) + tuple(a[:6]))
        return super().tighten(lo, hi, *a, **k)
    def draw_clipped(self, lines, color, surface, stats=None, roles=None):
        if in_target[0]: calls.append(('draw', tuple(lines)))
        return super().draw_clipped(lines, color, surface, stats, roles=roles)

def hook(idx, cl, *a, **k):
    in_target[0] = (idx == SS)
    if idx == SS:
        print(f"\n  spans before: {cl.spans}")
    r = orig_ss(idx, cl, *a, **k)
    if idx == SS:
        print(f"  spans after:  {cl.spans}")
    in_target[0] = False
    return r

dw.packed_render_subsector = hook
dw.fp_bbox_visible_fixed = reject_only
try:
    dw.packed_render_bsp(len(dw.nodes) - 1, Tap(), ctx, vz, PX, PY, cf, sf, surf, ram)
finally:
    dw.packed_render_subsector = orig_ss
    dw.fp_bbox_visible_fixed = orig_bbox

print("\ncalls during ss:")
for c in calls:
    print("  ", c)
