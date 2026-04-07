#!/usr/bin/env python3
"""Trace the projection outputs (sx1, sx2, ft1, fb1, ft2, fb2) for each seg
emitted by both the 6502 and Python FP at prescale=16 pos 0, matched by seg index."""
import os, sys, math
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import fe6502
import spans6502

POS = (1056, -3616, 0)

# ── Trace Python FP: patch FPClipSpans.has_gap at class level to capture
# (lo, hi) along with the current seg index tracked via fp_render_seg wrapper.
py_trace = []
_current_seg = [None]
_orig_has_gap = dw.FPClipSpans.has_gap
def _traced_has_gap(self, lo, hi):
    r = _orig_has_gap(self, lo, hi)
    if r and _current_seg[0] is not None:
        py_trace.append((_current_seg[0], lo, hi))
    return r
dw.FPClipSpans.has_gap = _traced_has_gap

_orig_fp_render_seg = dw.fp_render_seg
def _tracked_fp(si, *args, **kwargs):
    _current_seg[0] = si
    _orig_fp_render_seg(si, *args, **kwargs)
    _current_seg[0] = None
dw.fp_render_seg = _tracked_fp

# ── Trace 6502: capture queue_solid/queue_tighten args keyed by seg idx ──
hw_trace = []
hw_has_gap_segs = []  # segs that reached the per-seg has_gap call
_orig_hg = spans6502.SpanState.has_gap
def _hw_hg(self, mpu):
    ptr = self.mem[0x5E] | (self.mem[0x5F] << 8)
    base = 0x2000 + dw.packed_layout['off_seg_hdr']
    idx = (ptr - base) // 12
    hw_has_gap_segs.append(idx)
    _orig_hg(self, mpu)
spans6502.SpanState.has_gap = _hw_hg
_orig_qs = spans6502.SpanState.queue_solid
def _hw_qs(self, mpu):
    ptr = self.mem[0x5E] | (self.mem[0x5F] << 8)
    base = 0x2000 + dw.packed_layout['off_seg_hdr']
    idx = (ptr - base) // 12
    lo = spans6502._rs16(self.mem, spans6502.ZP_LO)
    hi = spans6502._rs16(self.mem, spans6502.ZP_HI)
    hw_trace.append((idx, 'S', lo, hi))
    _orig_qs(self, mpu)
spans6502.SpanState.queue_solid = _hw_qs

_orig_qt = spans6502.SpanState.queue_tighten
def _hw_qt(self, mpu):
    ptr = self.mem[0x5E] | (self.mem[0x5F] << 8)
    base = 0x2000 + dw.packed_layout['off_seg_hdr']
    idx = (ptr - base) // 12
    lo = spans6502._rs16(self.mem, spans6502.ZP_LO)
    hi = spans6502._rs16(self.mem, spans6502.ZP_HI)
    hw_trace.append((idx, 'P', lo, hi))
    _orig_qt(self, mpu)
spans6502.SpanState.queue_tighten = _hw_qt

px, py, ab = POS
fz = dw.player_floor(px, py)

# Python FP run
py_trace.clear()
for k in dw.map_trace:
    if hasattr(dw.map_trace[k], 'clear'):
        dw.map_trace[k].clear()
px_88 = int((px - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
py_88 = int((py - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
vz_ps = dw._prescale_height(fz + 41)
sc = dw.fp_sincos(ab)
ctx = dw.fp_view_context(px_88, py_88, sc)
ang_rad = dw.byte_to_radians(ab)
cos_f, sin_f = math.cos(ang_rad), math.sin(ang_rad)
tmp = pygame.Surface((dw.FP_RENDER_W, dw.FP_RENDER_H))
dw.render_bsp_fp(len(dw.nodes) - 1, dw.FPClipSpans(), ctx, vz_ps,
                 px, py, cos_f, sin_f, tmp,
                 [None] * len(dw.vertexes), [None] * len(dw.vwh_table))

# 6502 run
hw_trace.clear()
fe = fe6502.Frontend6502(dw.packed_rom_banks, dw.packed_rom_recip,
                          dw.packed_bbox_table, dw.packed_layout)
cmds, cyc = fe.render_frame(px, py, ab, fz)

print(f"PRESCALE={dw.PRESCALE}, pos={POS}")
print(f"Python FP traced: {len(py_trace)} emissions")
print(f"6502 traced:      {len(hw_trace)} emissions")
print()

# Match by seg index — only consider drawn (emitted) segs on both sides
# (has_gap returned True).  A seg can appear multiple times in py_trace if
# has_gap is called from multiple paths — dedupe keeping first.
py_by_idx = {}
for (si, lo, hi) in py_trace:
    if si not in py_by_idx:
        py_by_idx[si] = (lo, hi)
hw_by_idx = {si: (t, lo, hi) for (si, t, lo, hi) in hw_trace}

py_set = set(py_by_idx)
hw_set = set(hw_by_idx)

print(f"Segs only in Python:   {sorted(py_set - hw_set)[:20]}")
print(f"Segs only in 6502:     {sorted(hw_set - py_set)[:20]}")
print(f"Segs in both:          {len(py_set & hw_set)}")
print(f"6502 per-seg has_gap calls: {sorted(set(s for s in hw_has_gap_segs if s < 1000))[:80]}")
print()

# Compare lo/hi for segs in both
print("Segs in both, first 10 with diffs:")
for idx in sorted(py_set & hw_set):
    py_lo, py_hi = py_by_idx[idx]
    hw_t, hw_lo, hw_hi = hw_by_idx[idx]
    if (py_lo, py_hi) != (hw_lo, hw_hi):
        print(f"  seg {idx:>4}: py=({py_lo:>4},{py_hi:>4})  hw=({hw_lo:>4},{hw_hi:>4})  diff")
