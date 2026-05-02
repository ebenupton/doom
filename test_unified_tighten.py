#!/usr/bin/env python3
"""Compare unified_clip_tighten vs current tighten across the 9 scenes.

Wraps Instrumented6502Spans so each tighten call ALSO runs unified on a
clone of self.spans. After both run, asserts span states are identical.
The unified version with no emission callbacks should be algorithmically
equivalent to current tighten.
"""
import os, sys, math, copy
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import fp as fpmod
from endpoint_spans import EndpointClipSpans

POSITIONS = [
    (1056, -3616, 64, "S1_E"),
    (1056, -3616, 0,  "N"),
    (1056, -3616, 32, "S2_NE"),
    (1056, -3616, 96, "SE"),
    (1200, -3300, 64, "T_moved"),
    (964,  -3441, 79, "doorway"),
    (1200, -3300, 0,  "T_N"),
    (1200, -3300, 32, "T_NE"),
    (800,  -3500, 32, "spawn-W"),
]

# Counters
_divergence_count = [0]
_total_calls = [0]
_emitted_top = [0]
_emitted_bot = [0]


class CompareTighten(dw.Instrumented6502Spans):
    """Run current tighten via super, AND run unified on a clone, then compare."""

    def tighten(self, lo, hi, sx1, sx2, yt1, yt2, yb1, yb2,
                top_dom=False, bot_dom=False,
                emit_top=True, emit_bot=True,
                emit_sec_top=False, emit_sec_bot=False,
                yt_sec1=None, yt_sec2=None,
                yb_sec1=None, yb_sec2=None):
        from endpoint_spans import _compute_tighten_splits, EndpointClipSpans
        _total_calls[0] += 1
        spans_snapshot = list(self.spans)

        # Match wrapper bias and split semantics from
        # Instrumented6502Spans.tighten (lines 156-190 of doom_wireframe.py)
        yt1b, yt2b, yb1b, yb2b = self._bias_y(yt1, yt2, yb1, yb2)
        # Skip if no-op (matches wrapper's _AP_SKIP_ENABLE branch).
        skip_noop = (EndpointClipSpans.line_above_spans(self, sx1, yt1b, sx2, yt2b)
                     and EndpointClipSpans.line_below_spans(self, sx1, yb1b, sx2, yb2b))
        params_list = (
            [] if skip_noop
            else _compute_tighten_splits(lo, hi, sx1, sx2, yt1b, yt2b, yb1b, yb2b))

        # Run normal tighten via super (this also runs the 6502 shadow).
        super().tighten(lo, hi, sx1, sx2, yt1, yt2, yb1, yb2,
                        top_dom=top_dom, bot_dom=bot_dom,
                        emit_top=emit_top, emit_bot=emit_bot,
                        emit_sec_top=emit_sec_top, emit_sec_bot=emit_sec_bot,
                        yt_sec1=yt_sec1, yt_sec2=yt_sec2,
                        yb_sec1=yb_sec1, yb_sec2=yb_sec2)
        spans_after_normal = list(self.spans)

        # Reset to snapshot, then run unified for each split.
        self.spans = spans_snapshot
        self._update_bbox()
        captured_top = []
        captured_bot = []
        for params in params_list:
            self.unified_clip_tighten(
                *params,
                emit_top_to=lambda x1,y1,x2,y2: captured_top.append((x1,y1,x2,y2)),
                emit_bot_to=lambda x1,y1,x2,y2: captured_bot.append((x1,y1,x2,y2)))
        spans_after_unified = list(self.spans)

        # Restore canonical (normal tighten) state for further processing.
        self.spans = spans_after_normal
        self._update_bbox()

        _emitted_top[0] += len(captured_top)
        _emitted_bot[0] += len(captured_bot)

        if spans_after_normal != spans_after_unified:
            _divergence_count[0] += 1
            if _divergence_count[0] <= 5:
                print(f"DIVERGENCE call#{_total_calls[0]} "
                      f"lo={lo} hi={hi} sx=[{sx1},{sx2}] "
                      f"yt=[{yt1},{yt2}] yb=[{yb1},{yb2}]")
                print(f"  pre   ({len(spans_snapshot)}): {spans_snapshot[:3]}")
                print(f"  norm  ({len(spans_after_normal)}): {spans_after_normal[:3]}")
                print(f"  uni   ({len(spans_after_unified)}): {spans_after_unified[:3]}")


def render(px, py, ab):
    fz = dw.player_floor(px, py)
    real = pygame.draw.line
    pygame.draw.line = lambda *a, **k: None
    px_88 = int((px - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
    py_88 = int((py - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
    vz_ps = dw._prescale_height(fz + 41)
    sc = dw.fp_sincos(ab)
    ctx = dw.fp_view_context(px_88, py_88, sc)
    ang_rad = dw.byte_to_radians(ab)
    cos_f, sin_f = math.cos(ang_rad), math.sin(ang_rad)
    tmp = pygame.Surface((dw.FP_RENDER_W, dw.FP_RENDER_H))
    fpmod.mul_reset()
    from wad_packed import spans_init_full
    p_ram = dw._packed_ram_new()
    spans_base = dw.packed_layout['ram_spans']
    spans_init_full(p_ram, spans_base, dw.FP_RENDER_W, dw.FP_RENDER_H - 1)
    if dw._span_clip_6502 is not None:
        dw._span_clip_6502.clear_screen()
    clips = CompareTighten()
    dw.packed_render_bsp(len(dw.nodes) - 1, clips,
                         ctx, vz_ps, int(px), int(py), cos_f, sin_f,
                         tmp, p_ram)
    pygame.draw.line = real


# Ensure _span_clip_6502 is initialized
dw.Instrumented6502Spans()
for px, py, ab, name in POSITIONS:
    pre = _divergence_count[0]
    render(px, py, ab)
    after = _divergence_count[0]
    print(f"{name:<10s}  divergences: {after-pre}")

print()
print(f"Total tighten calls:  {_total_calls[0]}")
print(f"Total divergences:    {_divergence_count[0]}")
print(f"Top-line emits:       {_emitted_top[0]}")
print(f"Bot-line emits:       {_emitted_bot[0]}")
