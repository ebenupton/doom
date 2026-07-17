"""Shared loaders for engine binaries + generated tables into a py65 memory.

One definition of "where things go" — load addresses are parsed from the
SAME ld65 config the linker places code with (they cannot drift), symbol
addresses come from the linked symbol map, table contents from angle_bbox.
Replaces the per-test cloned load blocks that drifted (stale comments
disagreed about TA_HI/VATOX addresses).
"""
import os
import re

import asmbuild
from symmap import sym

_ROOT = asmbuild._ROOT


def _regions(banked=0):
    """Parse MEMORY areas from the engine ld65 config: [(start, file)]."""
    cfg = open(os.path.join(_ROOT, asmbuild._CFGS[banked])).read()
    mem = cfg[cfg.index('MEMORY'):cfg.index('SEGMENTS')]
    out = []
    for m in re.finditer(r'start\s*=\s*\$([0-9A-Fa-f]+)[^;]*?file\s*=\s*"([^"]+)"', mem):
        out.append((int(m.group(1), 16), m.group(2)))
    return out


def load_engine(mem, banked=0, c02=None):
    """Build the whole engine and load every output region into py65 memory.
    Regions sharing an output file concatenate in declaration order (the
    umul8 pin's zero-filled jump-table gap is part of the file)."""
    asmbuild.build('engine', banked=banked, c02=c02)
    loaded = set()
    for start, fname in _regions(banked):
        if fname in loaded:
            continue                     # later areas append to the same file
        loaded.add(fname)
        code = open(os.path.join(_ROOT, fname), 'rb').read()
        mem[start:start + len(code)] = code


def load_angle_module(mem, c02=None):
    """Build + load the flat angle module (slope_div) and its tables:
    code @ ang_head, F tables @ L8_TAB/AE_LO/AE_HI, viewangletox
    (centre-column, phi+512 index, u8-clamped) @ VATOX."""
    import angle_bbox as A
    # Build the ENGINE link (not the slope_div-only link): the ZC segment
    # (bbox corner zone arms, 2026-07-15) lives in the CODE region, and a
    # standalone slope_div link would place it at a different address than
    # the JSRs inside the ang bin expect. One link, one truth: load the
    # engine's CODE bin and its ang bin.
    asmbuild.build('engine', banked=0, c02=c02)
    code = open(os.path.join(_ROOT, 'bsp_render.bin'), 'rb').read()
    cbase = sym('code_head')                # CODE region head ($3670 flat)
    mem[cbase:cbase + len(code)] = code
    base = sym('ang_head')                  # ANG region head
    code = open(os.path.join(_ROOT, 'bsp_render_ang.bin'), 'rb').read()
    mem[base:base + len(code)] = code
    l8, ae_lo, ae_hi = sym('L8_TAB'), sym('AE_LO'), sym('AE_HI')
    vatox = sym('VATOX')
    # option F tables (tools/atanexp_cert.py is the one source; the
    # mirror loads the same json). Seed-time contract asserts:
    assert A.EPSILON_F == 15, 'EPSILON drifted from the baked bca_tail bias'
    assert A._TA0 == 0, 'TA0 drifted from the baked num==0 arm'
    for i in range(256):
        mem[l8 + i] = A._L8[i] & 0xFF
        mem[ae_lo + i] = A._ATANEXP[i] & 0xFF
        mem[ae_hi + i] = (A._ATANEXP[i] >> 8) & 0xFF
    for k in range(1025):
        c = (A._vatox_lo[k + 512] + A._vatox_hi[k + 512]) // 2
        mem[vatox + k] = max(0, min(255, c))
    # bca_tail bakes the table ends as constants (clamp/==1024 arms skip
    # the lookup): ilo(r=0) = VATOX[0]-1 -> 0, ihi(r=1024) = VATOX[1024]+1
    # -> 255. Seed must match the baked immediates.
    assert mem[vatox] == 0 and mem[vatox + 1024] == 255, \
        'VATOX ends drifted from bca_tail baked constants (0/255)'
