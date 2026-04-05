#!/usr/bin/env python3
"""Trace seg 672 specifically at prescale=16 pos 1 — find the arithmetic divergence."""
import os, math
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import fe6502
import spans6502
import fp

SEG = 672
POS = (1056, -3616, 0)
px, py, ab = POS

# ── Compute via Python FP ──
svwh = dw.fp_segs_vwh[SEG]
s = svwh[0]
v1_idx, v2_idx = s[0], s[1]
v1 = dw.fp_vertexes[v1_idx]
v2 = dw.fp_vertexes[v2_idx]
print(f"Seg {SEG}: v1={v1_idx}={v1}, v2={v2_idx}={v2}, ldx={svwh[13]}, ldy={svwh[14]}")

px_88 = int((px - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
py_88 = int((py - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
sc = dw.fp_sincos(ab)
ctx = dw.fp_view_context(px_88, py_88, sc)
print(f"\nPRESCALE={dw.PRESCALE}  px_88={px_88} py_88={py_88}")
print(f"ctx = {ctx}")

# Back-face test
ldx, ldy = svwh[13], svwh[14]
px_int, py_int = ctx[0], ctx[1]
dot = ldy * (px_int - v1[0]) - ldx * (py_int - v1[1])
if s[4] == 1:
    dot = -dot
print(f"\nBack-face: dot = {dot}  (front-facing if > 0)")
if dot <= 0:
    print("  culled!")
else:
    vc1 = fp.fp_to_view(v1[0], v1[1], ctx)
    vc2 = fp.fp_to_view(v2[0], v2[1], ctx)
    print(f"\nfp_to_view(v1): {vc1}")
    print(f"fp_to_view(v2): {vc2}")
    vx1, vy1 = vc1[1], vc1[2]
    vx2, vy2 = vc2[1], vc2[2]
    nc = fp.fp_near_clip(vx1, vy1, vx2, vy2)
    print(f"\nnear_clip: {nc}")
    if nc is not None:
        ex1, ey1, ex2, ey2 = nc
        idx1 = vc1[4] if ey1 == vy1 else (ey1 << fp.RECIP_FRAC_BITS)
        idx2 = vc2[4] if ey2 == vy2 else (ey2 << fp.RECIP_FRAC_BITS)
        rxh1, rxl1 = fp.fp_recip(idx1)
        rxh2, rxl2 = fp.fp_recip(idx2)
        sx1 = fp.fp_project_x(ex1, rxh1, rxl1)
        sx2 = fp.fp_project_x(ex2, rxh2, rxl2)
        print(f"  ex1={ex1} ey1={ey1} vi1={idx1} rxh1={rxh1} rxl1={rxl1}")
        print(f"  ex2={ex2} ey2={ey2} vi2={idx2} rxh2={rxh2} rxl2={rxl2}")
        print(f"  sx1={sx1}, sx2={sx2}")
        print(f"  x_lo={min(sx1,sx2)} x_hi={max(sx1,sx2)}")

# ── Capture 6502's values for seg 672 ──
captured = {}
fe = fe6502.Frontend6502(dw.packed_rom_main, dw.packed_rom_detail,
                          dw.packed_rom_recip, dw.packed_layout)
_orig_hg = spans6502.SpanState.has_gap
def _hw_hg(self, mpu):
    ptr = self.mem[0x5E] | (self.mem[0x5F] << 8)
    base = 0x2000 + dw.packed_layout['off_seg_hdr']
    idx = (ptr - base) // 12
    if idx == SEG:
        def rs16(a):
            v = self.mem[a] | (self.mem[a+1] << 8)
            return v - 65536 if v >= 32768 else v
        captured['vx1'] = rs16(0x30); captured['vy1'] = rs16(0x32); captured['vi1'] = rs16(0x34)
        captured['vx2'] = rs16(0x36); captured['vy2'] = rs16(0x38); captured['vi2'] = rs16(0x3A)
        captured['ex1'] = rs16(0x3C); captured['ey1'] = rs16(0x3E)
        captured['ex2'] = rs16(0x40); captured['ey2'] = rs16(0x42)
        captured['sx1'] = rs16(0x20); captured['sx2'] = rs16(0x22)
        captured['lo'] = rs16(0xA0); captured['hi'] = rs16(0xA2)
        captured['rxh'] = self.mem[0x44]; captured['rxl'] = self.mem[0x45]
    _orig_hg(self, mpu)
spans6502.SpanState.has_gap = _hw_hg
fe._span_hooks[spans6502.HK_HAS_GAP] = lambda mpu: _hw_hg(fe._span_state, mpu)

fz = dw.player_floor(px, py)
cmds, cyc = fe.render_frame(px, py, ab, fz)
print(f"\n6502 values for seg {SEG} at prescale={dw.PRESCALE}:")
if captured:
    for k in ('vx1','vy1','vi1','vx2','vy2','vi2','ex1','ey1','ex2','ey2','rxh','rxl','sx1','sx2','lo','hi'):
        print(f"  {k:5s} = {captured[k]}")
else:
    print("  (seg not reached by 6502's per-seg has_gap)")
