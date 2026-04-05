#!/usr/bin/env python3
"""Compare the BSP walk order (ssid sequence) between Python FP and the 6502."""
import os, math
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import fe6502
import spans6502

POS = (1056, -3616, 0)

# Python FP: track render_subsector_fp calls
py_order = []
_orig_render_ss_fp = dw.render_subsector_fp
def _py_render_ss(idx, *args, **kwargs):
    py_order.append(idx)
    _orig_render_ss_fp(idx, *args, **kwargs)
dw.render_subsector_fp = _py_render_ss

# 6502: track enter_ss hook calls
hw_order = []
fe = fe6502.Frontend6502(dw.packed_rom_main, dw.packed_rom_detail,
                          dw.packed_rom_recip, dw.packed_layout)
_orig_enter_ss = spans6502.SpanState.enter_ss
def _hw_enter_ss(self, mpu):
    _orig_enter_ss(self, mpu)
    ssid = self.ss_history[-1]
    hw_order.append(ssid)
spans6502.SpanState.enter_ss = _hw_enter_ss
fe._span_hooks[spans6502.HK_ENTER_SS] = lambda mpu: _hw_enter_ss(fe._span_state, mpu)

# Run both
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

print(f"PRESCALE={dw.PRESCALE}, pos={POS}")
print(f"Python FP visits {len(py_order)} subsectors: {py_order}")
print(f"6502     visits {len(hw_order)} subsectors: {hw_order}")
print()

n = min(len(py_order), len(hw_order))
for i in range(n):
    if py_order[i] != hw_order[i]:
        print(f"First diverging subsector at index {i}:")
        print(f"  Python: ssid={py_order[i]}")
        print(f"  6502:   ssid={hw_order[i]}")
        print(f"  Context (previous 3):  {py_order[max(0,i-3):i]}")
        print(f"  Python next:           {py_order[i:i+5]}")
        print(f"  6502 next:             {hw_order[i:i+5]}")
        break
else:
    if len(py_order) != len(hw_order):
        print(f"Lengths differ: py={len(py_order)} hw={len(hw_order)}")
    else:
        print("BSP walks matched!")
