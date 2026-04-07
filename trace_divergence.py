#!/usr/bin/env python3
"""Trace every FPClipSpans.has_gap call in the 6502 hook run and the Python FP run,
then diff them. This captures bbox + per-seg calls on both sides equivalently."""
import os, sys
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import fe6502
import spans6502
import math

POS = (1056, -3616, 0)  # pos 1: spawn North — the divergent one at p=16

# ── Patch FPClipSpans.has_gap at the class level — catches both the
# Python FP render path AND the bbox_cull/has_gap paths inside the 6502
# hook (both go through the same class method).
import traceback
calls = []
_orig_has_gap = dw.FPClipSpans.has_gap
_current_nid = [None]   # set by bbox_cull wrapper so has_gap sees it
def _traced(self, lo, hi):
    r = _orig_has_gap(self, lo, hi)
    frame = traceback.extract_stack()[-2]
    caller = f"{os.path.basename(frame.filename)}:{frame.lineno}"
    digest = tuple((s[0], s[1]) for s in self.spans)
    calls.append((lo, hi, bool(r), len(self.spans), caller, digest, _current_nid[0]))
    return r
dw.FPClipSpans.has_gap = _traced

# Use node identity to find nid on the Python side
_node_id_to_nid = {id(n): i for i, n in enumerate(dw.nodes)}
_orig_bbox_visible = dw.fp_bbox_visible
def _bbox_wrap(node, far_side, cos_a, sin_a, vx, vy):
    _current_nid[0] = ('py', _node_id_to_nid.get(id(node), -1), far_side)
    return _orig_bbox_visible(node, far_side, cos_a, sin_a, vx, vy)
dw.fp_bbox_visible = _bbox_wrap

_orig_hw_bbox = spans6502.SpanState.bbox_cull
def _hw_bbox_wrap(self, mpu):
    nid = self.mem[0xA0] | (self.mem[0xA1] << 8)
    far = self.mem[0xA4]
    _current_nid[0] = ('hw', nid & 0x7FFF, far)
    _orig_hw_bbox(self, mpu)
spans6502.SpanState.bbox_cull = _hw_bbox_wrap

px, py, ab = POS
fz = dw.player_floor(px, py)

# ── Run Python FP ────────────────────────────────────────────────────────────
calls.clear()
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
py_drawn = len(dw.map_trace['segs_drawn'])
py_calls = list(calls)

# ── Run 6502 ─────────────────────────────────────────────────────────────────
calls.clear()
fe = fe6502.Frontend6502(dw.packed_rom_banks, dw.packed_rom_recip,
                          dw.packed_bbox_table, dw.packed_layout)
cmds, cyc = fe.render_frame(px, py, ab, fz)
hw_drawn = sum(1 for c in cmds if c[0] in 'SP')
hw_calls = list(calls)

print(f"PRESCALE={dw.PRESCALE}, pos={POS}")
py_seg = sum(1 for c in py_calls if '1352' in c[4])
py_bbox = sum(1 for c in py_calls if '1525' in c[4])
hw_seg = sum(1 for c in hw_calls if '133' in c[4])
hw_bbox = sum(1 for c in hw_calls if '222' in c[4])
print(f"Python FP: {py_drawn} drawn,  {len(py_calls)} has_gap calls (seg={py_seg} bbox={py_bbox})")
print(f"6502 hook: {hw_drawn} S/P,     {len(hw_calls)} has_gap calls (seg={hw_seg} bbox={hw_bbox})")
print()

# ── Diff (ignore caller field; compare only lo, hi, gap, spans) ─────────────
def key(c):
    return c[:4]
n = min(len(py_calls), len(hw_calls))
div_idx = None
for i in range(n):
    if key(py_calls[i]) != key(hw_calls[i]):
        div_idx = i
        break
if div_idx is None and len(py_calls) != len(hw_calls):
    div_idx = n

if div_idx is None:
    print("All has_gap calls matched identically.")
else:
    print(f"First divergence at call #{div_idx}:")
    for j in range(max(0, div_idx - 3), min(n, div_idx + 5)):
        marker = "  <-- HERE" if j == div_idx else ""
        p = py_calls[j] if j < len(py_calls) else None
        h = hw_calls[j] if j < len(hw_calls) else None
        # Show lo,hi,gap,spans_count,caller,digest
        def fmt(c):
            if c is None: return "None"
            nid_info = c[6] if len(c) > 6 else None
            return f"lo={c[0]:>5} hi={c[1]:>5} gap={str(c[2]):5} spans={c[3]} {c[4]:<25} nid={nid_info}"
        print(f"  #{j:>3}  py {fmt(p)}")
        print(f"       hw {fmt(h)}{marker}")
    # If lengths differ, show a bit of the extra tail
    if len(py_calls) != len(hw_calls):
        print()
        print(f"py total: {len(py_calls)}, hw total: {len(hw_calls)}")
