#!/usr/bin/env python3
"""Capture the span state on both sides at the moment seg 672's has_gap is called."""
import os, math
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import fe6502
import spans6502
from wad_packed import read_all_spans, SPAN_HDR

SEG = 672
POS = (1056, -3616, 0)

# ── Trace Python FP: capture spans state when seg 672 calls has_gap ──
py_state = []
_current_seg = [None]
_orig_has_gap = dw.FPClipSpans.has_gap
def _traced(self, lo, hi):
    if _current_seg[0] == SEG:
        # Record the state at this moment
        py_state.append((lo, hi, list(self.spans)))
    return _orig_has_gap(self, lo, hi)
dw.FPClipSpans.has_gap = _traced

_orig_fp_render_seg = dw.fp_render_seg
def _tracked_fp(si, *args, **kwargs):
    _current_seg[0] = si
    _orig_fp_render_seg(si, *args, **kwargs)
    _current_seg[0] = None
dw.fp_render_seg = _tracked_fp

# ── Trace 6502: capture spans state when seg 672 calls has_gap hook ──
hw_state = []
fe = fe6502.Frontend6502(dw.packed_rom_main, dw.packed_rom_detail,
                          dw.packed_rom_recip, dw.packed_layout)
_orig_hw_hg = spans6502.SpanState.has_gap
def _hw_hg(self, mpu):
    ptr = self.mem[0x5E] | (self.mem[0x5F] << 8)
    base = 0x2000 + dw.packed_layout['off_seg_hdr']
    idx = (ptr - base) // 12
    if idx == SEG:
        lo = spans6502._rs16(self.mem, spans6502.ZP_LO)
        hi = spans6502._rs16(self.mem, spans6502.ZP_HI)
        spans = read_all_spans(self.mem, spans6502.SPANS_BASE)
        hw_state.append((lo, hi, spans))
    _orig_hw_hg(self, mpu)
spans6502.SpanState.has_gap = _hw_hg
fe._span_hooks[spans6502.HK_HAS_GAP] = lambda mpu: _hw_hg(fe._span_state, mpu)

# ── Run both ──
px, py, ab = POS
fz = dw.player_floor(px, py)

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

cmds, cyc = fe.render_frame(px, py, ab, fz)

print(f"PRESCALE={dw.PRESCALE}, pos={POS}, SEG={SEG}")
print()
print(f"Python FP captures ({len(py_state)}):")
for lo, hi, spans in py_state:
    print(f"  has_gap({lo}, {hi}), spans=")
    for s in spans:
        print(f"    xlo={s[0]} xhi={s[1]} tfn={s[2]} bfn={s[3]} inner=({s[4]},{s[5]}) outer=({s[6]},{s[7]})")
print()
print(f"6502 captures ({len(hw_state)}):")
for lo, hi, spans in hw_state:
    print(f"  has_gap({lo}, {hi}), spans=")
    for s in spans:
        print(f"    xlo={s[0]} xhi={s[1]} tfn={s[2]} bfn={s[3]} inner=({s[4]},{s[5]}) outer=({s[6]},{s[7]})")
