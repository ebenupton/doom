"""Shared loaders for engine binaries + generated tables into a py65 memory.

One definition of "where things go" — addresses come from the linked symbol
map, table contents from angle_bbox. Replaces the per-test cloned load
blocks that drifted (stale comments disagreed about TA_HI/VATOX addresses).
"""
import os

import asmbuild
from symmap import sym

_ROOT = asmbuild._ROOT


def load_angle_module(mem, c02=None):
    """Build + load the flat angle module (slope_div) and its tables:
    code @ jt_slope_div, tantoangle lo/hi @ TA_LO/TA_HI, viewangletox
    (centre-column, phi+512 index, u8-clamped) @ VATOX."""
    import angle_bbox as A
    asmbuild.build('slope_div', banked=0, c02=c02)
    base = sym('jt_slope_div')
    code = open(os.path.join(_ROOT, 'bsp_render_ang.bin'), 'rb').read()
    mem[base:base + len(code)] = code
    ta_lo, ta_hi, vatox = sym('TA_LO'), sym('TA_HI'), sym('VATOX')
    for i in range(1024):
        v = A._tantoangle[i]
        mem[ta_lo + i] = v & 0xFF
        mem[ta_hi + i] = (v >> 8) & 0xFF
    for k in range(1025):
        c = (A._vatox_lo[k + 512] + A._vatox_hi[k + 512]) // 2
        mem[vatox + k] = max(0, min(255, c))
