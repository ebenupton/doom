#!/usr/bin/env python3
"""Compare ASM clip_line_records vs Python clip_line_records during real renders.

Hooks into Instrumented6502Spans.tighten to capture seg parameters, then
runs both ASM and Python clip_line_records and checks records match.
"""
import os, math
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import fp as fpmod
from endpoint_spans import EndpointClipSpans, _compute_tighten_splits, _remap_seg_for_8bit
from span_clip_6502 import TOP_RECORDS, BOT_RECORDS

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

mismatches = []
total_calls = [0]


class CompareRecords(dw.Instrumented6502Spans):
    def tighten(self, lo, hi, sx1, sx2, yt1, yt2, yb1, yb2,
                top_dom=False, bot_dom=False,
                emit_top=True, emit_bot=True,
                emit_sec_top=False, emit_sec_bot=False,
                yt_sec1=None, yt_sec2=None,
                yb_sec1=None, yb_sec2=None):
        total_calls[0] += 1
        yt1b, yt2b, yb1b, yb2b = self._bias_y(yt1, yt2, yb1, yb2)
        # Skip detection (matches super behavior)
        if (EndpointClipSpans.line_above_spans(self, sx1, yt1b, sx2, yt2b)
                and EndpointClipSpans.line_below_spans(self, sx1, yb1b, sx2, yb2b)):
            super().tighten(lo, hi, sx1, sx2, yt1, yt2, yb1, yb2,
                            top_dom=top_dom, bot_dom=bot_dom,
                            emit_top=emit_top, emit_bot=emit_bot,
                            emit_sec_top=emit_sec_top, emit_sec_bot=emit_sec_bot,
                            yt_sec1=yt_sec1, yt_sec2=yt_sec2,
                            yb_sec1=yb_sec1, yb_sec2=yb_sec2)
            return

        # Get split params (post-bias)
        for params in _compute_tighten_splits(lo, hi, sx1, sx2, yt1b, yt2b, yb1b, yb2b):
            p_lo, p_hi, p_sx1, p_sx2, p_yt1, p_yt2, p_yb1, p_yb2 = params
            if p_sx1 > p_sx2:
                p_sx1, p_sx2 = p_sx2, p_sx1
                p_yt1, p_yt2 = p_yt2, p_yt1
                p_yb1, p_yb2 = p_yb2, p_yb1
            ilo_p = max(0, p_lo); ihi_p = min(255, p_hi)
            p_sx1, p_sx2, p_yt1, p_yt2, p_yb1, p_yb2 = _remap_seg_for_8bit(
                ilo_p, ihi_p, p_sx1, p_sx2, p_yt1, p_yt2, p_yb1, p_yb2,
                clamp_u8=(self.y_display_offset != 0))

            # Compare yt-line records
            for tag, lx1, ly1, lx2, ly2, buf in [
                    ('yt', p_sx1, p_yt1, p_sx2, p_yt2, TOP_RECORDS),
                    ('yb', p_sx1, p_yb1, p_sx2, p_yb2, BOT_RECORDS)]:
                py_recs = EndpointClipSpans.clip_line_records(
                    self, lx1, ly1, lx2, ly2, ilo=ilo_p, ihi=ihi_p)
                asm_recs = dw._span_clip_6502.clip_line_records(
                    lx1, ly1, lx2, ly2, ilo_p, ihi_p, buf)
                # Compare on content (ignore si — it's pool slot vs span idx).
                py_sorted = sorted(
                    [(r['sox0'], r['sox1'], r['verdict']) for r in py_recs])
                asm_sorted = sorted(
                    [(r['sox0'], r['sox1'], r['verdict']) for r in asm_recs])
                if py_sorted != asm_sorted:
                    if len(mismatches) < 5:
                        mismatches.append({
                            'call': total_calls[0],
                            'tag': tag,
                            'line': (lx1, ly1, lx2, ly2),
                            'ilo_ihi': (ilo_p, ihi_p),
                            'py': py_sorted,
                            'asm': asm_sorted,
                        })

            # Now actually run super (so render proceeds)
            super().tighten(lo, hi, sx1, sx2, yt1, yt2, yb1, yb2,
                            top_dom=top_dom, bot_dom=bot_dom,
                            emit_top=emit_top, emit_bot=emit_bot,
                            emit_sec_top=emit_sec_top, emit_sec_bot=emit_sec_bot,
                            yt_sec1=yt_sec1, yt_sec2=yt_sec2,
                            yb_sec1=yb_sec1, yb_sec2=yb_sec2)
            return  # (super loops over splits internally)


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
    dw._span_clip_6502.clear_screen()
    clips = CompareRecords()
    dw.packed_render_bsp(len(dw.nodes) - 1, clips,
                         ctx, vz_ps, int(px), int(py), cos_f, sin_f,
                         tmp, p_ram)
    pygame.draw.line = real


# Initialize
dw.Instrumented6502Spans()
for px, py, ab, name in POSITIONS:
    render(px, py, ab)
    print(f"{name:<10s}  total tighten calls so far: {total_calls[0]}")

print()
print(f"Total tighten calls: {total_calls[0]}")
print(f"Records mismatches:  {len(mismatches)}")
for m in mismatches:
    print(f"  call#{m['call']} {m['tag']} line={m['line']} ilo_ihi={m['ilo_ihi']}")
    print(f"    py:  {m['py']}")
    print(f"    asm: {m['asm']}")
