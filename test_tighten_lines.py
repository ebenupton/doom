#!/usr/bin/env python3
"""Verification harness: compare 6502 tighten line emission vs Python prediction.

For each position/angle, replays the BSP operation sequence and after each
tighten call, compares the lines drained from the 6502 against the output of
compute_expected_tighten_lines().
"""
import os, math, sys

os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'

import pygame
pygame.init()
pygame.display.set_mode((1, 1))

import doom_wireframe as dw
import fp as fpmod
from span_clip_6502 import SpanClip6502
from endpoint_spans import (EndpointClipSpans, _compute_tighten_splits,
                            _remap_seg_for_8bit, compute_expected_tighten_lines)
from wad_packed import spans_init_full

positions = [
    (1056, -3616, 64),
    (505, -3268, 125),
    (1965, -3320, 187),
    (1200, -3316, 10),
    (800, -3800, 45),
    (1324, -3146, 252),
    (1098, -3026, 159),
]

total_frames = 0
total_tightens = 0
total_match = 0
total_mismatch = 0
total_6502_extra = 0
total_6502_missing = 0
total_degenerate = 0  # x1==x2 lines from 6502

# Categories of mismatch
cat_pm1_rounding = 0
cat_degenerate_extra = 0
cat_other = 0

mismatch_examples = []


def classify_mismatch(expected, actual):
    """Classify a mismatch between expected and actual line sets."""
    extra = []
    missing = []
    matched_e = set()
    matched_a = set()

    # Try exact match first
    e_set = {}
    for i, l in enumerate(expected):
        e_set.setdefault(l, []).append(i)
    a_set = {}
    for i, l in enumerate(actual):
        a_set.setdefault(l, []).append(i)

    for l in list(e_set.keys()):
        if l in a_set:
            n = min(len(e_set[l]), len(a_set[l]))
            for _ in range(n):
                matched_e.add(e_set[l].pop())
                matched_a.add(a_set[l].pop())
            if not e_set[l]:
                del e_set[l]
            if not a_set[l]:
                del a_set[l]

    for i, l in enumerate(expected):
        if i not in matched_e:
            missing.append(l)
    for i, l in enumerate(actual):
        if i not in matched_a:
            extra.append(l)

    return extra, missing


def is_pm1(line_a, line_b):
    """Check if two lines differ by at most 1px in each coordinate."""
    return all(abs(a - b) <= 1 for a, b in zip(line_a, line_b))


def run_frame(px, py, pa, angle, sc, verbose=False):
    global total_tightens, total_match, total_mismatch
    global total_6502_extra, total_6502_missing, total_degenerate
    global cat_pm1_rounding, cat_degenerate_extra, cat_other

    sc.init()
    fpmod.mul_reset()

    px88 = int((px - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
    py88 = int((py - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
    vz = dw._prescale_height(dw.player_floor(px, py) + 41)
    ctx = dw.fp_view_context(px88, py88, dw.fp_sincos(angle))
    cf = math.cos(dw.byte_to_radians(angle))
    sf = math.sin(dw.byte_to_radians(angle))

    ref = EndpointClipSpans()
    ops = []

    oms = EndpointClipSpans.mark_solid
    otg = EndpointClipSpans.tighten

    def hm(s, lo, hi):
        ops.append(('ms', lo, hi))
        oms(s, lo, hi)

    def ht(s, *a, **k):
        for p in _compute_tighten_splits(*a[:8]):
            ops.append(('tg',) + p)
            otg(s, *p, **k)

    EndpointClipSpans.mark_solid = hm
    EndpointClipSpans.tighten = ht

    pr = dw._packed_ram_new()
    spans_init_full(pr, dw.packed_layout['ram_spans'], dw.FP_RENDER_W, dw.FP_RENDER_H - 1)
    dw.packed_render_bsp(len(dw.nodes) - 1, ref, ctx, vz,
                         int(px), int(py), cf, sf,
                         pygame.Surface((256, 160)), pr)

    EndpointClipSpans.mark_solid = oms
    EndpointClipSpans.tighten = otg

    # Now replay on the 6502, comparing line output after each tighten
    py_spans = EndpointClipSpans()
    frame_match = 0
    frame_mismatch = 0

    for op in ops:
        if op[0] == 'ms':
            sc.mark_solid(op[1], op[2])
            py_spans.mark_solid(op[1], op[2])
            sc.drain_lines()  # clear any mark_solid lines
        else:
            # Tighten
            lo, hi, s1, s2, t1, t2, b1, b2 = op[1:]

            # Get pre-mutation spans for expected line computation
            pre_spans = list(py_spans.spans)

            # Compute remapped params (matching what the 6502 wrapper does)
            ilo = max(0, lo)
            ihi = min(255, hi)
            rs1, rs2, rt1, rt2, rb1, rb2 = s1, s2, t1, t2, b1, b2
            if rs1 > rs2:
                rs1, rs2 = rs2, rs1
                rt1, rt2 = rt2, rt1
                rb1, rb2 = rb2, rb1
            rs1, rs2, rt1, rt2, rb1, rb2 = _remap_seg_for_8bit(
                ilo, ihi, rs1, rs2, rt1, rt2, rb1, rb2)

            # Compute expected lines
            expected = compute_expected_tighten_lines(
                pre_spans, ilo, ihi, rs1, rs2, rt1, rt2, rb1, rb2)

            # Run 6502 tighten
            sc.tighten(*op[1:])
            actual = sc.drain_lines()

            # Run Python tighten
            py_spans.tighten(*op[1:])

            total_tightens += 1

            # Count degenerate lines in 6502 output
            for l in actual:
                if l[0] == l[2]:
                    total_degenerate += 1
                    if verbose and total_degenerate <= 5:
                        print(f'  DEGENERATE from 6502: {l} in tighten [{lo},{hi}]')
                        print(f'    remapped: sx={rs1},{rs2} yt={rt1},{rt2} yb={rb1},{rb2}')
                        print(f'    pre_spans ({len(pre_spans)}): {pre_spans[:3]}...')

            if sorted(expected) == sorted(actual):
                total_match += 1
                frame_match += 1
            else:
                total_mismatch += 1
                frame_mismatch += 1
                extra, missing = classify_mismatch(expected, actual)
                total_6502_extra += len(extra)
                total_6502_missing += len(missing)

                # Classify
                for e_line in extra:
                    if e_line[0] == e_line[2]:
                        cat_degenerate_extra += 1
                    elif any(is_pm1(e_line, m_line) for m_line in missing):
                        cat_pm1_rounding += 1
                    else:
                        cat_other += 1
                for m_line in missing:
                    if not any(is_pm1(m_line, e_line) for e_line in extra):
                        cat_other += 1

                if len(mismatch_examples) < 10:
                    mismatch_examples.append({
                        'pos': (px, py, angle),
                        'op': op,
                        'expected': expected,
                        'actual': actual,
                        'extra': extra,
                        'missing': missing,
                    })
                if verbose and frame_mismatch <= 3:
                    print(f'  MISMATCH tighten [{lo},{hi}]:')
                    print(f'    expected={expected}')
                    print(f'    actual  ={actual}')
                    print(f'    extra   ={extra}')
                    print(f'    missing ={missing}')

    return frame_match, frame_mismatch


def main():
    global total_frames
    sc = SpanClip6502()
    verbose = '-v' in sys.argv

    for px, py, pa in positions:
        pos_match = 0
        pos_mismatch = 0
        for a in range(0, 256, 2):
            angle = (pa + a) % 256
            m, mm = run_frame(px, py, pa, angle, sc, verbose=verbose)
            pos_match += m
            pos_mismatch += mm
            total_frames += 1
        print(f'  Pos ({px},{py},{pa}): {pos_match} match, {pos_mismatch} mismatch '
              f'out of {pos_match + pos_mismatch} tightens')

    print()
    print('=' * 60)
    print(f'Total frames: {total_frames}')
    print(f'Total tightens: {total_tightens}')
    print(f'  Match: {total_match} ({100*total_match/max(1,total_tightens):.1f}%)')
    print(f'  Mismatch: {total_mismatch} ({100*total_mismatch/max(1,total_tightens):.1f}%)')
    print(f'  6502 extra lines: {total_6502_extra}')
    print(f'  6502 missing lines: {total_6502_missing}')
    print(f'  Degenerate (x1==x2) from 6502: {total_degenerate}')
    print()
    print('Mismatch categories:')
    print(f'  +/-1px rounding: {cat_pm1_rounding}')
    print(f'  Degenerate extra: {cat_degenerate_extra}')
    print(f'  Other: {cat_other}')

    if mismatch_examples:
        print()
        print('First few mismatch examples:')
        for i, ex in enumerate(mismatch_examples[:5]):
            print(f'  Example {i}: pos={ex["pos"]}')
            print(f'    op={ex["op"]}')
            print(f'    expected={ex["expected"]}')
            print(f'    actual  ={ex["actual"]}')
            print(f'    extra   ={ex["extra"]}')
            print(f'    missing ={ex["missing"]}')


if __name__ == '__main__':
    main()
