#!/usr/bin/env python3
"""Reproduce and trace the call#6 yb mismatch.
seg: line=(65, 160, 96, 144), ilo_ihi=(65, 96).
Expected: span at (66, 74) records 'below' (per Python), ASM says 'inside'.
"""
import os
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

from span_clip_6502 import SpanClip6502, BOT_RECORDS, ZP_LINE_XL, ZP_LINE_YL, ZP_LINE_XR, ZP_LINE_YR, ZP_ILO, ZP_IHI, ZP_BUF, ENTRY_CLIP_LINE_RECORDS, POOL_BASE
from endpoint_spans import EndpointClipSpans, _interp_store, Y_BIAS

# Set up a pool state matching what Python sees at call#6.
# Need to know the actual span list at that moment. Without exact replay,
# let's set up a simulated pool with one span at (66, 74) and capture
# both Python and ASM records.

sc = SpanClip6502()
sc.clear_screen()
sc.init()  # full-screen span at slot 1

mem = sc.mpu.memory

# Manually replace slot 1 with a span (66, 74) — narrowed.
# POOL_NEXT=$0400, POOL_XLO=$0420, POOL_DEN=$0440, etc.
slot = 1
mem[0x0400 + slot] = 0  # next = end
mem[0x0420 + slot] = 56  # POOL_XLO (line anchor)
mem[0x0440 + slot] = 199 - 56  # POOL_DEN = xhi - xlo = 199-56 = 143
mem[0x0460 + slot] = 111  # POOL_TL
mem[0x04A0 + slot] = 155  # POOL_TR
mem[0x0480 + slot] = 111  # POOL_BL — flat at 111? hmm, for "narrowed" not sure
mem[0x04C0 + slot] = 155  # POOL_BR
mem[0x04E0 + slot] = 66   # XSTART
mem[0x0500 + slot] = 74   # XEND

# Hmm I don't know the exact pool state at the failing call. Let me just
# reproduce the issue via a render and dump.

print("Rebuilding via real render path...")
import doom_wireframe as dw
import math, fp as fpmod
from endpoint_spans import _compute_tighten_splits, _remap_seg_for_8bit

sc = dw._span_clip_6502 if dw._span_clip_6502 else None
if sc is None:
    dw.Instrumented6502Spans()
    sc = dw._span_clip_6502


traced = []


class TracedClips(dw.Instrumented6502Spans):
    def tighten(self, lo, hi, sx1, sx2, yt1, yt2, yb1, yb2,
                top_dom=False, bot_dom=False,
                emit_top=True, emit_bot=True,
                emit_sec_top=False, emit_sec_bot=False,
                yt_sec1=None, yt_sec2=None,
                yb_sec1=None, yb_sec2=None):
        # Capture the FIRST yb-line where the bot crossing case applies
        # (matching the test#6 description).
        yt1b, yt2b, yb1b, yb2b = self._bias_y(yt1, yt2, yb1, yb2)
        # Skip detection
        if (EndpointClipSpans.line_above_spans(self, sx1, yt1b, sx2, yt2b)
                and EndpointClipSpans.line_below_spans(self, sx1, yb1b, sx2, yb2b)):
            super().tighten(lo, hi, sx1, sx2, yt1, yt2, yb1, yb2,
                            top_dom=top_dom, bot_dom=bot_dom,
                            emit_top=emit_top, emit_bot=emit_bot,
                            emit_sec_top=emit_sec_top, emit_sec_bot=emit_sec_bot,
                            yt_sec1=yt_sec1, yt_sec2=yt_sec2,
                            yb_sec1=yb_sec1, yb_sec2=yb_sec2)
            return

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

            # Specifically check for the call#6 yb signature
            if p_sx1 == 65 and p_sx2 == 96 and p_yb1 == 160 and p_yb2 == 144:
                # Capture state
                py_recs = EndpointClipSpans.clip_line_records(
                    self, p_sx1, p_yb1, p_sx2, p_yb2, ilo=ilo_p, ihi=ihi_p)
                asm_recs = dw._span_clip_6502.clip_line_records(
                    p_sx1, p_yb1, p_sx2, p_yb2, ilo_p, ihi_p, BOT_RECORDS)
                # Also dump pool state for slots that might be involved
                mem = dw._span_clip_6502.mpu.memory
                pool_dump = []
                slot = mem[0x0400] >> 0  # head — actually head is in zp
                # iterate via head from zp
                head_slot = mem[0xC0]  # zp_head
                while head_slot != 0:
                    pool_dump.append({
                        'slot': head_slot,
                        'xlo': mem[0x0420 + head_slot],
                        'den': mem[0x0440 + head_slot],
                        'tl': mem[0x0460 + head_slot],
                        'bl': mem[0x0480 + head_slot],
                        'tr': mem[0x04A0 + head_slot],
                        'br': mem[0x04C0 + head_slot],
                        'xstart': mem[0x04E0 + head_slot],
                        'xend': mem[0x0500 + head_slot],
                    })
                    head_slot = mem[0x0400 + head_slot]
                traced.append({
                    'py_recs': py_recs,
                    'asm_recs': asm_recs,
                    'pool': pool_dump,
                    'spans': list(self.spans),
                })

            super().tighten(lo, hi, sx1, sx2, yt1, yt2, yb1, yb2,
                            top_dom=top_dom, bot_dom=bot_dom,
                            emit_top=emit_top, emit_bot=emit_bot,
                            emit_sec_top=emit_sec_top, emit_sec_bot=emit_sec_bot,
                            yt_sec1=yt_sec1, yt_sec2=yt_sec2,
                            yb_sec1=yb_sec1, yb_sec2=yb_sec2)
            return


def render(px, py, ab):
    fz = dw.player_floor(px, py)
    real = pygame.draw.line
    pygame.draw.line = lambda *a, **k: None
    px_88 = int((px - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
    py_88 = int((py - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
    vz_ps = dw._prescale_height(fz + 41)
    sc_v = dw.fp_sincos(ab)
    ctx = dw.fp_view_context(px_88, py_88, sc_v)
    ang_rad = dw.byte_to_radians(ab)
    cos_f, sin_f = math.cos(ang_rad), math.sin(ang_rad)
    tmp = pygame.Surface((dw.FP_RENDER_W, dw.FP_RENDER_H))
    fpmod.mul_reset()
    from wad_packed import spans_init_full
    p_ram = dw._packed_ram_new()
    spans_base = dw.packed_layout['ram_spans']
    spans_init_full(p_ram, spans_base, dw.FP_RENDER_W, dw.FP_RENDER_H - 1)
    dw._span_clip_6502.clear_screen()
    clips = TracedClips()
    dw.packed_render_bsp(len(dw.nodes) - 1, clips,
                         ctx, vz_ps, int(px), int(py), cos_f, sin_f,
                         tmp, p_ram)
    pygame.draw.line = real


# Run S1_E (where call#6 occurs)
render(1056, -3616, 64)

if not traced:
    print("Did not capture the call#6 yb scenario")
else:
    t = traced[0]
    print(f"Pool state (active spans):")
    for p in t['pool']:
        print(f"  slot={p['slot']} xstart={p['xstart']} xend={p['xend']} "
              f"xlo={p['xlo']} den={p['den']} "
              f"tl={p['tl']} bl={p['bl']} tr={p['tr']} br={p['br']}")
    print(f"Python self.spans:")
    for s in t['spans']:
        print(f"  {s}")
    print(f"Python records:")
    for r in t['py_recs']:
        print(f"  {r}")
    print(f"ASM records:")
    for r in t['asm_recs']:
        print(f"  {r}")
