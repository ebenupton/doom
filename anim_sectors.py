#!/usr/bin/env python3
"""Runtime sector-height animation (doors / lifts) — Python prototype.

Requires the DOOM_ANIM=1 build (doom_wireframe: movers discovered from
linedef specials, their segs exempt from strip/NOVT, private VWH slots).

The Mover class owns per-sector patch lists mapping a height change onto
the exact bytes the renderer reads — the same contract the 6502 patcher
will implement:
  - rom_detail: SD_FH/SD_CH (segs whose FRONT is the mover),
                SD_BFH/SD_BCH (segs whose BACK is the mover)
  - rom_main:   private VWH height bytes (ANIM_VWH_SLOTS),
                seg-header FLAGS (SF_SOLID/NEEDBT/NEEDBB re-derived from
                the current heights, exactly the packer's rules)
  - python:     sectors[] / fp_sectors[] (float truth + player_floor)

DOOM rest-height rules: a door opens to (lowest neighbour ceiling - 4);
a lift descends to the lowest neighbour floor; a type-36 floor lowers to
(highest neighbour floor + 8).
"""
import os

assert os.environ.get('DOOM_ANIM') == '1', 'set DOOM_ANIM=1 before importing'

import doom_wireframe as dw
from wad_packed import (SEG_DTL_SIZE, SEG_HDR_SIZE, SD_FH, SD_CH, SD_BFH,
                        SD_BCH, SH_FLAGS, SF_SOLID, SF_NEEDBT, SF_NEEDBB)

_LAYOUT = dw.packed_layout
_ROM_MAIN = dw.packed_rom_main          # bytearray — shared with _p_rom_main
_ROM_DETAIL = dw.packed_rom_detail
_OFF_SEG_HDR = _LAYOUT['off_seg_hdr']
_OFF_VWH = _LAYOUT['off_vwh']


def _neighbours(sec):
    """Sector indices sharing a linedef with `sec`."""
    out = set()
    for ld in dw.linedefs:
        sides = [s for s in (ld[5], ld[6]) if s != 0xFFFF]
        secs = [dw.sidedefs[s][5] for s in sides]
        if sec in secs:
            out.update(x for x in secs if x != sec)
    return out


class Mover:
    def __init__(self, sec):
        kind = dw.ANIM_SECTORS[sec]     # 'ceil' (door) | 'floor' (lift etc.)
        self.sec = sec
        self.kind = kind
        s = dw.sectors[sec]
        self.floor, self.ceil = s[0], s[1]          # current raw heights
        nb = [dw.sectors[n] for n in _neighbours(sec)]
        if kind == 'ceil':                          # door
            self.closed = self.floor                # ceil at floor = shut
            self.open = min(n[1] for n in nb) - 4
        else:                                       # lift / lowering floor
            self.top = self.floor
            self.bottom = min(n[0] for n in nb)
        # patch lists: (detail_byte_offset_fh, detail_byte_offset_ch) per seg
        self.front_segs = []                        # seg idx, front == sec
        self.back_segs = []                         # seg idx, back == sec
        for i, svwh in enumerate(dw.fp_segs_vwh):
            if svwh[1] == sec:
                self.front_segs.append(i)
            if svwh[2] == sec:
                self.back_segs.append(i)
        self.touch_segs = sorted(set(self.front_segs) | set(self.back_segs))

    # ── the byte patcher ─────────────────────────────────────────────
    def set_heights(self, floor=None, ceil=None):
        """Set raw heights; write every byte the renderer reads."""
        if floor is None: floor = self.floor
        if ceil is None: ceil = self.ceil
        self.floor, self.ceil = floor, ceil
        sec = self.sec
        # python-side sector tables (float truth, player_floor)
        s = dw.sectors[sec]
        dw.sectors[sec] = (floor, ceil) + tuple(s[2:])
        fps = dw.fp_sectors[sec]
        fh_ps = dw._prescale_height(floor)
        ch_ps = dw._prescale_height(ceil)
        dw.fp_sectors[sec] = (fh_ps, ch_ps) + tuple(fps[2:])
        # private VWH slots
        for idx in dw.ANIM_VWH_SLOTS.get((sec, 'f'), ()):
            _ROM_MAIN[_OFF_VWH + idx] = fh_ps & 0xFF
        for idx in dw.ANIM_VWH_SLOTS.get((sec, 'c'), ()):
            _ROM_MAIN[_OFF_VWH + idx] = ch_ps & 0xFF
        # seg detail heights
        for i in self.front_segs:
            o = i * SEG_DTL_SIZE
            _ROM_DETAIL[o + SD_FH] = fh_ps & 0xFF
            _ROM_DETAIL[o + SD_CH] = ch_ps & 0xFF
        for i in self.back_segs:
            o = i * SEG_DTL_SIZE
            _ROM_DETAIL[o + SD_BFH] = fh_ps & 0xFF
            _ROM_DETAIL[o + SD_BCH] = ch_ps & 0xFF
        # seg flags: re-derive SOLID/NEEDBT/NEEDBB from current heights
        # (identical rules to wad_packed.build_packed)
        for i in self.touch_segs:
            svwh = dw.fp_segs_vwh[i]
            fi, bi = svwh[1], svwh[2]
            if bi is None:
                continue
            ffh, fch = dw.fp_sectors[fi][0], dw.fp_sectors[fi][1]
            bfh, bch = dw.fp_sectors[bi][0], dw.fp_sectors[bi][1]
            o = _OFF_SEG_HDR + i * SEG_HDR_SIZE + SH_FLAGS
            f = _ROM_MAIN[o] & ~(SF_SOLID | SF_NEEDBT | SF_NEEDBB)
            if bch <= ffh or bfh >= fch:
                f |= SF_SOLID
            else:
                if bch < fch: f |= SF_NEEDBT
                if bfh > ffh: f |= SF_NEEDBB
            _ROM_MAIN[o] = f

    # ── motion helpers ───────────────────────────────────────────────
    def phase(self, t):
        """t=0 rest/closed .. t=1 fully open/lowered (linear)."""
        if self.kind == 'ceil':
            self.set_heights(ceil=round(self.closed + t * (self.open - self.closed)))
        else:
            self.set_heights(floor=round(self.top + t * (self.bottom - self.top)))


MOVERS = {sec: Mover(sec) for sec in dw.ANIM_SECTORS}


def camera_for(mover, dist=170.0):
    """Viewpoint in front of the mover's largest outside-facing seg."""
    import math
    best = None
    for i in mover.back_segs or mover.front_segs:
        svwh = dw.fp_segs_vwh[i]
        s = svwh[0]
        v1, v2 = dw.vertexes[s[0]], dw.vertexes[s[1]]
        L = math.hypot(v2[0] - v1[0], v2[1] - v1[1])
        if best is None or L > best[0]:
            best = (L, s, v1, v2, i in mover.back_segs)
    L, s, v1, v2, backside = best
    mx, my = (v1[0] + v2[0]) / 2, (v1[1] + v2[1]) / 2
    dx, dy = v2[0] - v1[0], v2[1] - v1[1]
    # DOOM: front sector is on the RIGHT of v1->v2. seg[4]=1 flips direction.
    nx, ny = dy / L, -dx / L
    if s[4] == 1:
        nx, ny = -nx, -ny
    if not backside:                    # front==mover: camera on the back side
        nx, ny = -nx, -ny
    cx, cy = mx + nx * dist, my + ny * dist
    ang = math.atan2(my - cy, mx - cx)  # face the seg
    ab = round(ang * 256 / (2 * math.pi)) & 0xFF
    return int(cx), int(cy), ab


def fb_to_surface(fb):
    import pygame
    surf = pygame.Surface((256, 160))
    px = pygame.PixelArray(surf)
    for y in range(160):
        base = ((y >> 3) << 8) + (y & 7)
        for xb in range(32):
            b = fb[base + xb * 8]
            if b:
                for bit in range(8):
                    if b & (0x80 >> bit):
                        px[xb * 8 + bit, y] = (255, 255, 255)
    del px
    return surf
