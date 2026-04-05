#!/usr/bin/env python3
"""Trace has_gap calls from the 6502 and Python FP paths at pos 1, diff them."""
import os
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
from fe6502 import Frontend6502
import spans6502
import math

POS = (1056, -3616, 0)  # E1M1 start North — the divergent pos at p=8

# ── Capture has_gap calls on the Python FP side ──────────────────────────────
py_calls = []
_orig_has_gap = dw.FPClipSpans.has_gap
def _py_traced(self, lo, hi):
    r = _orig_has_gap(self, lo, hi)
    py_calls.append((lo, hi, bool(r), len(self.spans)))
    return r
dw.FPClipSpans.has_gap = _py_traced

# ── Capture has_gap calls on the 6502 side (via hook) ────────────────────────
hw_calls = []
_orig_hw = spans6502.SpanState.has_gap
def _hw_traced(self, mpu):
    lo = spans6502._rs16(self.mem, spans6502.ZP_LO)
    hi = spans6502._rs16(self.mem, spans6502.ZP_HI)
    clips = self._get_clips()
    r = clips.has_gap(lo, hi)
    hw_calls.append((lo, hi, bool(r), len(clips.spans)))
    spans6502._set_carry(mpu, r)
spans6502.SpanState.has_gap = _hw_traced

# ── Run both ─────────────────────────────────────────────────────────────────
px, py, ab = POS
fz = dw.player_floor(px, py)

# Python FP
py_calls.clear()
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
py_drawn = len(dw.map_trace['segs_drawn'])

# 6502
hw_calls.clear()
fe = Frontend6502(dw.packed_rom_main, dw.packed_rom_detail,
                  dw.packed_rom_recip, dw.packed_layout)
cmds, cyc = fe.render_frame(px, py, ab, fz)
hw_drawn = sum(1 for c in cmds if c[0] in 'SP')

print(f"Python FP: {py_drawn} drawn, {len(py_calls)} has_gap calls")
print(f"6502 hook: {hw_drawn} S/P cmds, {len(hw_calls)} has_gap calls")
print()

# Diff the calls
for i, (py, hw) in enumerate(zip(py_calls, hw_calls)):
    if py != hw:
        print(f"First divergence at call #{i}:")
        print(f"  Python: lo={py[0]:>4} hi={py[1]:>4} gap={py[2]!s:5} spans={py[3]}")
        print(f"  6502:   lo={hw[0]:>4} hi={hw[1]:>4} gap={hw[2]!s:5} spans={hw[3]}")
        # Show a few calls before/after for context
        print("\nContext:")
        for j in range(max(0, i-3), min(len(py_calls), i+4)):
            marker = " <-- HERE" if j == i else ""
            print(f"  #{j:>3}  py {py_calls[j]!r}  hw {hw_calls[j]!r}{marker}")
        break
else:
    if len(py_calls) != len(hw_calls):
        print(f"Calls differ in length: py={len(py_calls)} hw={len(hw_calls)}")
        start = min(len(py_calls), len(hw_calls))
        extra_source = "6502" if len(hw_calls) > len(py_calls) else "python"
        extra = (hw_calls if len(hw_calls) > len(py_calls) else py_calls)[start:start+5]
        print(f"{extra_source} has {len(extra)} extra calls starting:")
        for c in extra:
            print(f"  {c!r}")
    else:
        print("All has_gap calls matched!")
