#!/usr/bin/env python3
"""Per-tighten-call comparison: ASM records-driven vs ASM regular.
Hooks Instrumented6502Spans.tighten, runs both paths on a span snapshot,
compares results.
"""
import os, math, copy
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
multi_record_calls = [0]


def snapshot_pool(sc):
    """Return copy of POOL state (slots 0-31) and head pointer."""
    mem = sc.mpu.memory
    pool = []
    for slot in range(32):
        pool.append({
            'next': mem[0x0400 + slot],
            'xlo': mem[0x0420 + slot],
            'den': mem[0x0440 + slot],
            'tl':  mem[0x0460 + slot],
            'bl':  mem[0x0480 + slot],
            'tr':  mem[0x04A0 + slot],
            'br':  mem[0x04C0 + slot],
            'xstart': mem[0x04E0 + slot],
            'xend':   mem[0x0500 + slot],
            'ot':  mem[0x0520 + slot],
            'ob':  mem[0x0540 + slot],
            'it':  mem[0x0560 + slot],
            'ib':  mem[0x0580 + slot],
        })
    head = mem[0xC0]
    free = mem[0xC1]
    return pool, head, free


def restore_pool(sc, pool, head, free):
    mem = sc.mpu.memory
    for slot in range(32):
        p = pool[slot]
        mem[0x0400 + slot] = p['next']
        mem[0x0420 + slot] = p['xlo']
        mem[0x0440 + slot] = p['den']
        mem[0x0460 + slot] = p['tl']
        mem[0x0480 + slot] = p['bl']
        mem[0x04A0 + slot] = p['tr']
        mem[0x04C0 + slot] = p['br']
        mem[0x04E0 + slot] = p['xstart']
        mem[0x0500 + slot] = p['xend']
        mem[0x0520 + slot] = p['ot']
        mem[0x0540 + slot] = p['ob']
        mem[0x0560 + slot] = p['it']
        mem[0x0580 + slot] = p['ib']
    mem[0xC0] = head
    mem[0xC1] = free


def get_active_spans(sc):
    """Walk active span list, return list of dicts."""
    mem = sc.mpu.memory
    head = mem[0xC0]
    spans = []
    while head != 0:
        spans.append({
            'slot': head,
            'xstart': mem[0x04E0 + head],
            'xend':   mem[0x0500 + head],
            'xlo': mem[0x0420 + head],
            'den': mem[0x0440 + head],
            'tl': mem[0x0460 + head], 'bl': mem[0x0480 + head],
            'tr': mem[0x04A0 + head], 'br': mem[0x04C0 + head],
        })
        head = mem[0x0400 + head]
    return spans


class Compare(dw.Instrumented6502Spans):
    def tighten(self, lo, hi, sx1, sx2, yt1, yt2, yb1, yb2,
                top_dom=False, bot_dom=False,
                emit_top=True, emit_bot=True,
                emit_sec_top=False, emit_sec_bot=False,
                yt_sec1=None, yt_sec2=None,
                yb_sec1=None, yb_sec2=None):
        total_calls[0] += 1
        sc = dw._span_clip_6502
        # Snapshot POOL + zp_head/free
        pool_snap, head_snap, free_snap = snapshot_pool(sc)

        # Run regular ASM tighten
        import span_clip_6502 as scm
        scm._USE_6502_RECORDS_TIGHTEN = False
        super().tighten(lo, hi, sx1, sx2, yt1, yt2, yb1, yb2,
                        top_dom=top_dom, bot_dom=bot_dom,
                        emit_top=emit_top, emit_bot=emit_bot,
                        emit_sec_top=emit_sec_top, emit_sec_bot=emit_sec_bot,
                        yt_sec1=yt_sec1, yt_sec2=yt_sec2,
                        yb_sec1=yb_sec1, yb_sec2=yb_sec2)
        regular_spans = get_active_spans(sc)
        regular_pool, regular_head, regular_free = snapshot_pool(sc)

        # Restore, run records-driven
        restore_pool(sc, pool_snap, head_snap, free_snap)
        # Reset Python self.spans to match snapshot — easier: re-render in
        # reverse via super(). Hmm complex. Just check ASM POOL state.
        scm._USE_6502_RECORDS_TIGHTEN = True
        # Need to call _span_clip_6502.tighten directly with same params.
        # Same prep as super().tighten does internally.
        yt1b, yt2b, yb1b, yb2b = self._bias_y(yt1, yt2, yb1, yb2)
        if (EndpointClipSpans.line_above_spans(self, sx1, yt1b, sx2, yt2b)
                and EndpointClipSpans.line_below_spans(self, sx1, yb1b, sx2, yb2b)):
            scm._USE_6502_RECORDS_TIGHTEN = False
            return

        for params in _compute_tighten_splits(lo, hi, sx1, sx2, yt1b, yt2b, yb1b, yb2b):
            sc.tighten(*params, emit_top=emit_top, emit_bot=emit_bot)
        records_spans = get_active_spans(sc)

        # Detect multi-record (crossover) cases via top/bot record counts
        mem = sc.mpu.memory
        top_count = mem[TOP_RECORDS]
        bot_count = mem[BOT_RECORDS]
        # If any si appears >1 time in either buffer → multi-record
        multi = False
        for buf, cnt in [(TOP_RECORDS, top_count), (BOT_RECORDS, bot_count)]:
            seen = {}
            for i in range(cnt):
                si = mem[buf + 1 + i*6]
                seen[si] = seen.get(si, 0) + 1
            if any(v > 1 for v in seen.values()):
                multi = True
                break
        if multi:
            multi_record_calls[0] += 1

        # Compare
        if regular_spans != records_spans:
            mismatches.append({
                'call': total_calls[0],
                'multi': multi,
                'lo_hi': (lo, hi),
                'regular': regular_spans,
                'records': records_spans,
            })

        # Disable records mode for the rest of the render
        scm._USE_6502_RECORDS_TIGHTEN = False


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
    clips = Compare()
    dw.packed_render_bsp(len(dw.nodes) - 1, clips,
                         ctx, vz_ps, int(px), int(py), cos_f, sin_f,
                         tmp, p_ram)
    pygame.draw.line = real


dw.Instrumented6502Spans()
for px, py, ab, name in POSITIONS:
    render(px, py, ab)

print(f"Total tighten calls:    {total_calls[0]}")
print(f"Multi-record calls:     {multi_record_calls[0]}")
print(f"Mismatches:             {len(mismatches)}")
for m in mismatches[:5]:
    print(f"  call#{m['call']} multi={m['multi']} lo_hi={m['lo_hi']}")
    print(f"    regular: {[(s['xstart'], s['xend'], s['tl'], s['bl'], s['tr'], s['br']) for s in m['regular']]}")
    print(f"    records: {[(s['xstart'], s['xend'], s['tl'], s['bl'], s['tr'], s['br']) for s in m['records']]}")
