#!/usr/bin/env python3
"""Force has_gap = True on both sides and see if back-face/near-clip/projection give the same seg set."""
import os, sys
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import fe6502
import spans6502
import math

POS = (1056, -3616, 64)

# Disable ALL visibility state mutation on both sides so we're purely
# comparing back-face + near-clip + projection.
dw.FPClipSpans.has_gap = lambda self, lo, hi: True
dw.FPClipSpans.is_full = lambda self: False
dw.FPClipSpans.mark_solid = lambda self, lo, hi: None
dw.FPClipSpans.tighten = lambda self, *a, **k: None
dw.FPClipSpans.line_survives = lambda self, *a: False
dw.FPClipSpans.draw_clipped = lambda self, *a, **k: None
# Also force fp_bbox_visible to always return "visible everything" so
# Python FP's BSP traversal doesn't cull on bbox.
dw.fp_bbox_visible = lambda *args: (0, dw.FP_RENDER_W - 1)

hook_counts = {'has_gap': 0, 'bbox_cull': 0, 'queue_solid': 0, 'queue_tighten': 0, 'flush': 0, 'is_full': 0, 'init': 0}
def _cnt(name, fn):
    def wrapper(self, mpu):
        hook_counts[name] += 1
        return fn(self, mpu)
    return wrapper
spans6502.SpanState.has_gap = _cnt('has_gap', lambda self, mpu: spans6502._set_carry(mpu, True))
spans6502.SpanState.bbox_cull = _cnt('bbox_cull', lambda self, mpu: spans6502._set_carry(mpu, True))
spans6502.SpanState.is_full = _cnt('is_full', lambda self, mpu: spans6502._set_carry(mpu, False))
spans6502.SpanState.queue_solid = _cnt('queue_solid', lambda self, mpu: None)
spans6502.SpanState.queue_tighten = _cnt('queue_tighten', lambda self, mpu: None)
spans6502.SpanState.flush = _cnt('flush', lambda self, mpu: None)
_orig_init = spans6502.SpanState.init
def _init_wrap(self, mpu):
    hook_counts['init'] += 1
    return _orig_init(self, mpu)
spans6502.SpanState.init = _init_wrap

px, py, ab = POS
fz = dw.player_floor(px, py)

# Python FP run
for k in dw.map_trace:
    if hasattr(dw.map_trace[k], 'clear'):
        dw.map_trace[k].clear()
dw.fp_module.mul_reset()
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
py_segs = list(dw.map_trace['segs_drawn'])
py_ss = list(dw.map_trace['subsectors'])
print(f"Python FP with has_gap=True: {len(py_segs)} drawn, {len(py_ss)} subsectors visited")

# 6502 run
fe = fe6502.Frontend6502(dw.packed_rom_main, dw.packed_rom_detail,
                          dw.packed_rom_recip, dw.packed_layout)
cmds, cyc = fe.render_frame(px, py, ab, fz)
hw_cmds = [c for c in cmds if c[0] in 'SP']
hw_endss = sum(1 for c in cmds if c[0] == 'E')
print(f"6502 with has_gap=True:      {len(hw_cmds)} S/P cmds, {hw_endss} subsectors visited")
print(f"6502 hook counts: {hook_counts}")
