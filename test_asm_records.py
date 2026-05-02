#!/usr/bin/env python3
"""Verify ASM clip_line_records produces the same records as Python.

Tests an isolated case: load a known set of spans, call ASM clip_line_records,
compare with Python clip_line_records output.
"""
import os
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))

from span_clip_6502 import SpanClip6502, TOP_RECORDS
from endpoint_spans import EndpointClipSpans, Y_BIAS


def setup_initial_span(sc):
    """Initialize 6502 spans and return matching Python spans."""
    sc.clear_screen()
    sc.init()
    es = EndpointClipSpans()
    # Make Python use Y_BIAS to match 6502
    s = es.spans[0]
    es.spans = [(s[0], s[1], s[2], s[3],
                 s[4] + Y_BIAS, s[5] + Y_BIAS,
                 s[6] + Y_BIAS, s[7] + Y_BIAS,
                 s[8], s[9])] if len(s) > 8 else [(s[0], s[1], s[2], s[3],
                 s[4] + Y_BIAS, s[5] + Y_BIAS,
                 s[6] + Y_BIAS, s[7] + Y_BIAS)]
    es.y_display_offset = Y_BIAS
    es._update_bbox()
    return es


def compare_records(asm_recs, py_recs, label):
    """Compare ASM records (list of dicts) vs Python records (list of dicts)."""
    if len(asm_recs) != len(py_recs):
        print(f"{label}: count mismatch — asm={len(asm_recs)} py={len(py_recs)}")
        print(f"  asm: {asm_recs}")
        print(f"  py:  {py_recs}")
        return False
    diffs = 0
    for i, (a, p) in enumerate(zip(asm_recs, py_recs)):
        # Python record has 'sox0', 'sox1', 'verdict', and optionally 'cy0', 'cy1'.
        # ASM record always has all fields; cy0/cy1 are 0 for non-inside.
        if (a['si'] != i or  # span index — Python doesn't have si in same form
                a['sox0'] != p['sox0'] or
                a['sox1'] != p['sox1'] or
                a['verdict'] != p['verdict']):
            diffs += 1
            print(f"  rec[{i}] mismatch: asm={a} py={p}")
        elif p['verdict'] == 'inside':
            if a['cy0'] != p.get('cy0', 0) or a['cy1'] != p.get('cy1', 0):
                diffs += 1
                print(f"  rec[{i}] inside cy mismatch: asm cy0={a['cy0']} cy1={a['cy1']}; "
                      f"py cy0={p.get('cy0')} cy1={p.get('cy1')}")
    return diffs == 0


# Test 1: simple full-screen span, line crossing aperture
sc = SpanClip6502()
es = setup_initial_span(sc)
# Line that's fully inside the aperture (yt-line, biased)
xl, yl, xr, yr = 50, 100, 200, 100
ilo, ihi = 50, 200
asm_recs = sc.clip_line_records(xl, yl, xr, yr, ilo, ihi, TOP_RECORDS)
py_recs = es.clip_line_records(xl, yl, xr, yr, ilo=ilo, ihi=ihi)

# Annotate Python records with si (span index in self.spans)
py_normalized = []
for r in py_recs:
    py_normalized.append({
        'si': r.get('si', 0),  # may be different scheme
        'sox0': r['sox0'],
        'sox1': r['sox1'],
        'verdict': r['verdict'],
        'cy0': r.get('cy0', 0),
        'cy1': r.get('cy1', 0),
    })

print("Test 1: line fully inside aperture")
print(f"  asm: {asm_recs}")
print(f"  py:  {py_normalized}")
print()

# Test 2: line above aperture
xl, yl, xr, yr = 50, 30, 200, 30  # y=30 is above span_top (Y_BIAS=48)
asm_recs = sc.clip_line_records(xl, yl, xr, yr, ilo, ihi, TOP_RECORDS)
py_recs = es.clip_line_records(xl, yl, xr, yr, ilo=ilo, ihi=ihi)
print("Test 2: line above aperture")
print(f"  asm: {asm_recs}")
print(f"  py:  {py_recs}")
print()
