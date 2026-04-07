#!/usr/bin/env python3
"""Dump the span state on both sides after each subsector flush — find the first diverging state."""
import os, math
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import fe6502
import spans6502
from wad_packed import read_all_spans

POS = (1056, -3616, 0)

def _spans_digest(spans):
    """Return a tuple representation that can be compared."""
    return tuple((s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7]) for s in spans)

# ── Trace Python FP: capture spans at each subsector flush ──
py_states = []
_orig_render_ss_fp = dw.render_subsector_fp
def _py_render_ss(idx, clips, ctx, vz, surface, vcache, vwh_cache):
    _orig_render_ss_fp(idx, clips, ctx, vz, surface, vcache, vwh_cache)
    py_states.append((idx, _spans_digest(clips.spans)))
dw.render_subsector_fp = _py_render_ss

# ── Trace 6502: capture spans at each flush hook call ──
hw_states = []
fe = fe6502.Frontend6502(dw.packed_rom_banks, dw.packed_rom_recip,
                          dw.packed_bbox_table, dw.packed_layout)
# Also capture which subsector the 6502 just flushed.  We need to read
# zp_seg_hdr_ptr AT ENTRY to render_subsector; simplest proxy is the value
# of zp_tmp0 seen by render_subsector, which is the ssid.  Since
# render_subsector has returned by the time flush runs, use the first
# seg_hdr_ptr of the subsector as a proxy (stored in seg_loop before
# decrement).  Actually simplest: track queue_solid/queue_tighten in order
# with ptr, then associate ssid at flush time.
# Build seg -> ssid map
_seg_to_ssid = {}
for _ssid, (_count, _first) in enumerate(dw.fp_ssectors):
    for _s in range(_first, _first + _count):
        _seg_to_ssid[_s] = _ssid

_last_ssid_seen = [None]
_orig_qs = spans6502.SpanState.queue_solid
_orig_qt = spans6502.SpanState.queue_tighten
def _capture_ssid(self, mpu):
    ptr = self.mem[0x5E] | (self.mem[0x5F] << 8)
    base = 0x2000 + dw.packed_layout['off_seg_hdr']
    seg_idx = (ptr - base) // 12
    _last_ssid_seen[0] = _seg_to_ssid.get(seg_idx)
def _hw_qs(self, mpu):
    _capture_ssid(self, mpu)
    _orig_qs(self, mpu)
def _hw_qt(self, mpu):
    _capture_ssid(self, mpu)
    _orig_qt(self, mpu)
spans6502.SpanState.queue_solid = _hw_qs
spans6502.SpanState.queue_tighten = _hw_qt
fe._span_hooks[spans6502.HK_QUEUE_SOLID] = lambda mpu: _hw_qs(fe._span_state, mpu)
fe._span_hooks[spans6502.HK_QUEUE_TIGHTEN] = lambda mpu: _hw_qt(fe._span_state, mpu)

_orig_flush = spans6502.SpanState.flush
def _hw_flush(self, mpu):
    _orig_flush(self, mpu)
    spans = read_all_spans(self.mem, spans6502.SPANS_BASE)
    hw_states.append((_last_ssid_seen[0], _spans_digest(spans)))
    _last_ssid_seen[0] = None
spans6502.SpanState.flush = _hw_flush
fe._span_hooks[spans6502.HK_FLUSH] = lambda mpu: _hw_flush(fe._span_state, mpu)
fe._span_hooks[spans6502.HK_QUEUE_SOLID] = lambda mpu: _hw_qs(fe._span_state, mpu)
fe._span_hooks[spans6502.HK_QUEUE_TIGHTEN] = lambda mpu: _hw_qt(fe._span_state, mpu)

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

print(f"PRESCALE={dw.PRESCALE}, pos={POS}")
print(f"Python FP subsectors flushed: {len(py_states)}")
print(f"6502     subsectors flushed:  {len(hw_states)}")
print()

# Find the first divergence
n = min(len(py_states), len(hw_states))
for i in range(n):
    py_ssid, py_digest = py_states[i]
    hw_last_seg, hw_digest = hw_states[i]
    if py_digest != hw_digest:
        print(f"First diverging flush: #{i}")
        print(f"  Python ssid={py_ssid}  (py digest has {len(py_digest)} spans)")
        print(f"  6502 last-seen seg={hw_last_seg}  (hw digest has {len(hw_digest)} spans)")
        # Previous state for context
        if i > 0:
            prev_py_ssid, prev_py = py_states[i-1]
            prev_hw_seg, prev_hw = hw_states[i-1]
            print(f"  Previous py ssid={prev_py_ssid}, hw seg={prev_hw_seg}")
        break
else:
    print("All flushes matched!")
