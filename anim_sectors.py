#!/usr/bin/env python3
"""Runtime sector-height animation (doors / lifts) — Python prototype.

Requires the DOOM_ANIM=1 build (doom_wireframe: movers discovered from
linedef specials, their segs exempt from strip/NOVT, private VWH slots).

Two-level state, mirroring the intended 6502 design:

  LOGICAL heights advance every frame (Mover.tick — a few bytes of state
  machine, no table writes).  APPLIED heights are what every render read
  surface holds; they are brought up to date only when the mover can
  actually be seen: install() hooks the per-subsector entry of both python
  render paths, and a build-time subsector->movers mask triggers a patch
  the first time a frame visits any subsector containing one of the
  mover's segs.  An invisible mover's stale bytes are never read, so lazy
  and eager patching produce byte-identical frames (tools/anim_lazy_check).

A patch (Mover._apply) writes every byte the renderers read, atomically:
  python fp path:  fp_segs_vwh tuples (front fh/ch), vwh_table private
                   slots, fp_sectors, sectors (float truth + player_floor)
  packed path:     rom_detail SD_FH/CH + SD_BFH/BCH, rom_main private VWH
                   bytes + seg-header SOLID/NEEDBT/NEEDBB (re-derived with
                   the packer's rules)
  attached 6502s:  the same bytes at the flat memory-map addresses
                   (FHCH 6-byte condensation, VWH table, seg headers)

DOOM rest heights: door opens to lowest neighbour ceiling - 4; lift
descends to lowest neighbour floor; type-36 floors use the same bottom.
"""
import os

# (DOOM_ANIM gate removed 2026-07-10: anim is the only variant)

import doom_wireframe as dw
from wad_packed import (SEG_DTL_SIZE, SEG_HDR_SIZE, SD_FH, SD_CH, SD_BFH,
                        SD_BCH, SH_FLAGS, SF_SOLID, SF_NEEDBT, SF_NEEDBB)

_LAYOUT = dw.packed_layout
_ROM_MAIN = dw.packed_rom_main          # bytearray — shared with _p_rom_main
_ROM_DETAIL = dw.packed_rom_detail
_OFF_SEG_HDR = _LAYOUT['off_seg_hdr']

# speeds (world units / second) and dwell times (seconds)
DOOR_SPEED = 140.0
LIFT_SPEED = 120.0
DOOR_WAIT_CLOSED, DOOR_WAIT_OPEN = 1.6, 2.2
LIFT_WAIT_TOP, LIFT_WAIT_BOTTOM = 2.0, 1.4

STATS = {'ticks': 0, 'applies': 0, 'bytes': 0, 'frame_applies': 0}

# attached 6502 renderers: list of (memory, base addresses) — see attach_6502
_attached = []


def _neighbours(sec):
    out = set()
    for ld in dw.linedefs:
        sides = [s for s in (ld[5], ld[6]) if s != 0xFFFF]
        secs = [dw.sidedefs[s][5] for s in sides]
        if sec in secs:
            out.update(x for x in secs if x != sec)
    return out


class Mover:
    def __init__(self, sec):
        self.sec = sec
        self.kind = dw.ANIM_SECTORS[sec]        # 'ceil' (door) | 'floor'
        s = dw.sectors[sec]
        self.applied_floor, self.applied_ceil = s[0], s[1]
        nb = [dw.sectors[n] for n in _neighbours(sec)]
        if self.kind == 'ceil':                 # door
            self.closed = s[0]                  # ceil at floor = shut
            self.open = min(n[1] for n in nb) - 4
            self.pos = float(self.applied_ceil)
            self.state, self.timer = 'wait_closed', DOOR_WAIT_CLOSED
        else:                                   # lift / lowering floor
            self.top = s[0]
            self.bottom = min(n[0] for n in nb)
            self.pos = float(self.applied_floor)
            self.state, self.timer = 'wait_top', LIFT_WAIT_TOP
        # patch lists over the FINAL (merged) packed seg list
        self.front_segs = [i for i, sv in enumerate(dw.fp_segs_vwh) if sv[1] == sec]
        self.back_segs = [i for i, sv in enumerate(dw.fp_segs_vwh) if sv[2] == sec]
        self.touch_segs = sorted(set(self.front_segs) | set(self.back_segs))
        # remember each private VWH slot's vertex (table entries are tuples)
        self.vwh_f = [(i, dw.vwh_table[i][0]) for i in dw.ANIM_VWH_SLOTS.get((sec, 'f'), ())]
        self.vwh_c = [(i, dw.vwh_table[i][0]) for i in dw.ANIM_VWH_SLOTS.get((sec, 'c'), ())]

    # ── logical state (cheap, every frame) ───────────────────────────
    @property
    def floor(self):
        return round(self.pos) if self.kind != 'ceil' else self.applied_floor

    @property
    def ceil(self):
        return round(self.pos) if self.kind == 'ceil' else self.applied_ceil

    @property
    def dirty(self):
        return (self.floor != self.applied_floor
                or self.ceil != self.applied_ceil)

    def tick(self, dt):
        """Advance the continuous open/close (or up/down) cycle."""
        STATS['ticks'] += 1
        if self.kind == 'ceil':
            lo, hi = self.closed, self.open
            if self.state == 'wait_closed':
                self.timer -= dt
                if self.timer <= 0: self.state = 'opening'
            elif self.state == 'opening':
                self.pos = min(hi, self.pos + DOOR_SPEED * dt)
                if self.pos >= hi: self.state, self.timer = 'wait_open', DOOR_WAIT_OPEN
            elif self.state == 'wait_open':
                self.timer -= dt
                if self.timer <= 0: self.state = 'closing'
            else:
                self.pos = max(lo, self.pos - DOOR_SPEED * dt)
                if self.pos <= lo: self.state, self.timer = 'wait_closed', DOOR_WAIT_CLOSED
        else:
            lo, hi = self.bottom, self.top
            if self.state == 'wait_top':
                self.timer -= dt
                if self.timer <= 0: self.state = 'down'
            elif self.state == 'down':
                self.pos = max(lo, self.pos - LIFT_SPEED * dt)
                if self.pos <= lo: self.state, self.timer = 'wait_bottom', LIFT_WAIT_BOTTOM
            elif self.state == 'wait_bottom':
                self.timer -= dt
                if self.timer <= 0: self.state = 'up'
            else:
                self.pos = min(hi, self.pos + LIFT_SPEED * dt)
                if self.pos >= hi: self.state, self.timer = 'wait_top', LIFT_WAIT_TOP

    # ── the byte patcher (only when visible or flushed) ──────────────
    def flush(self):
        if self.dirty:
            self._apply()

    def _apply(self):
        floor, ceil = self.floor, self.ceil
        self.applied_floor, self.applied_ceil = floor, ceil
        sec = self.sec
        STATS['applies'] += 1
        STATS['frame_applies'] += 1
        nbytes = 0
        # python-side sector tables (float truth, player_floor)
        s = dw.sectors[sec]
        dw.sectors[sec] = (floor, ceil) + tuple(s[2:])
        fh_ps = dw._prescale_height(floor)
        ch_ps = dw._prescale_height(ceil)
        fps = dw.fp_sectors[sec]
        dw.fp_sectors[sec] = (fh_ps, ch_ps) + tuple(fps[2:])
        # fp-path seg tuples (front fh/ch live in the tuple)
        for i in self.front_segs:
            sv = dw.fp_segs_vwh[i]
            dw.fp_segs_vwh[i] = sv[:3] + (fh_ps, ch_ps) + sv[5:]
        # private VWH slots: python cache-key table only (the ROM copies were
        # write-only and are stripped — 6502 projects from FHCH heights)
        for idx, vert in self.vwh_f:
            dw.vwh_table[idx] = (vert, fh_ps)
        for idx, vert in self.vwh_c:
            dw.vwh_table[idx] = (vert, ch_ps)
        # packed seg detail + 6502 FHCH condensation
        for i in self.front_segs:
            o = i * SEG_DTL_SIZE
            _ROM_DETAIL[o + SD_FH] = fh_ps & 0xFF
            _ROM_DETAIL[o + SD_CH] = ch_ps & 0xFF
            for mem, base in _attached:
                mem[base['seg_hdr'] + i * SEG_HDR_SIZE + 12] = fh_ps & 0xFF
                mem[base['seg_hdr'] + i * SEG_HDR_SIZE + 13] = ch_ps & 0xFF
            nbytes += 2
        for i in self.back_segs:
            o = i * SEG_DTL_SIZE
            _ROM_DETAIL[o + SD_BFH] = fh_ps & 0xFF
            _ROM_DETAIL[o + SD_BCH] = ch_ps & 0xFF
            for mem, base in _attached:
                mem[base['seg_hdr'] + i * SEG_HDR_SIZE + 14] = fh_ps & 0xFF
                mem[base['seg_hdr'] + i * SEG_HDR_SIZE + 15] = ch_ps & 0xFF
            nbytes += 2
        # seg flags: re-derive SOLID/NEEDBT/NEEDBB (the packer's rules)
        for i in self.touch_segs:
            sv = dw.fp_segs_vwh[i]
            fi, bi = sv[1], sv[2]
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
            for mem, base in _attached:
                mem[base['seg_hdr'] + i * SEG_HDR_SIZE + SH_FLAGS] = f
            nbytes += 1
        STATS['bytes'] += nbytes

    # ── scripted access (demo strips) ────────────────────────────────
    def phase(self, t):
        """t=0 rest/closed .. t=1 fully open/lowered; applies eagerly."""
        if self.kind == 'ceil':
            self.pos = self.closed + t * (self.open - self.closed)
        else:
            self.pos = self.top + t * (self.bottom - self.top)
        self.flush()


MOVERS = {sec: Mover(sec) for sec in dw.ANIM_SECTORS}

# ── subsector -> movers mask (which movers a visited ss can reveal) ─────
_seg_to_ss = {}
for _ssi, (_cnt, _first) in enumerate(dw.fp_ssectors):
    for _k in range(_first, _first + _cnt):
        _seg_to_ss[_k] = _ssi
SS_MOVERS = {}
for _sec, _m in MOVERS.items():
    for _i in _m.touch_segs:
        SS_MOVERS.setdefault(_seg_to_ss[_i], []).append(_m)


def tick(dt):
    """Advance every mover's logical state (no table writes)."""
    STATS['frame_applies'] = 0
    for m in MOVERS.values():
        m.tick(dt)


def _ss_hook(ss_idx):
    ms = SS_MOVERS.get(ss_idx)
    if ms:
        for m in ms:
            m.flush()


def install():
    """Enable lazy visibility-driven patching in both python render paths."""
    dw._anim_ss_hook = _ss_hook


def uninstall():
    dw._anim_ss_hook = None


def flush_all():
    """Eager patch (6502-mode frames, demos, ground-truth renders)."""
    for m in MOVERS.values():
        m.flush()


def attach_6502(renderer):
    """Mirror every patch into a flat BspRender6502's py65 memory."""
    import bsp_render_6502 as br
    _attached.append((renderer.sc.mpu.memory, {
        'seg_hdr': br.ROM_SEG_HDR_BASE,
    }))


def hud_line():
    n_dirty = sum(1 for m in MOVERS.values() if m.dirty)
    states = ' '.join(f"s{m.sec}:{m.state[:4]}" for m in MOVERS.values())
    return (f"anim {STATS['frame_applies']} applied/frame, {n_dirty} dirty, "
            f"{STATS['bytes']}B total  {states}")


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


# ── 6502 table generation ───────────────────────────────────────────────
#
# Emits the exact byte tables src/bsp/anim.s consumes, for either address
# space. Mover bit m = index in sorted(ANIM_SECTORS) everywhere (SSMASK,
# TABL0/TABL2 pointer slots, CFG stride, ANIM_WS blocks).
#
# CFG (12 B/mover): min88, max88, speed88 (all prescaled 8.8), wait_at_A,
# wait_at_B (frames, <=63), start88, start state/timer byte, pad.
# Doors (ceil): A=closed, B=open, start at A. Lifts (floor): A=bottom,
# B=top, start waiting at B.

ANIM_SPEED_WORLD = {'ceil': 12, 'floor': 10}      # world units / frame
ANIM_WAITS = {'ceil': (14, 20), 'floor': (12, 18)}  # frames at A, at B


def _speed88(world_per_frame):
    # world/frame -> prescaled 8.8 per frame (exact packer rounding)
    return max(1, dw._prescale_height(world_per_frame * 256))


def gen_6502_tables(flat=True):
    """{address: bytes} for the flat harness or the banked window space."""
    import struct as _st
    if flat:
        import bsp_render_6502 as br
        A = dict(ssmask=0xE484, tabl0=0xE580, cfg=0xE680,
                 hdr=br.ROM_SEG_HDR_BASE)
    else:
        A = dict(ssmask=0x0A80, tabl0=0xBE90, cfg=0xBA00, hdr=0x9000)
    order = sorted(dw.ANIM_SECTORS)
    out = {}
    # SSMASK
    mask = bytearray(len(dw.fp_ssectors))
    for ssi, ms in SS_MOVERS.items():
        for m in ms:
            mask[ssi] |= 1 << order.index(m.sec)
    out[A['ssmask']] = bytes(mask)
    # TABL0: 6 ptrs + blocks (FHCH byte addrs for the MOVING role + flag entries)
    ptrs = bytearray(12)
    blocks = bytearray()
    base0 = A['tabl0']
    for mi, sec in enumerate(order):
        m = MOVERS[sec]
        addr = base0 + 12 + len(blocks)
        _st.pack_into('<H', ptrs, mi * 2, addr)
        fhch_addrs = []
        H = lambda i, k: A['hdr'] + i * SEG_HDR_SIZE + 12 + k
        if m.kind == 'ceil':
            fhch_addrs += [H(i, 1) for i in m.front_segs]  # ch
            fhch_addrs += [H(i, 3) for i in m.back_segs]   # bch
        else:
            fhch_addrs += [H(i, 0) for i in m.front_segs]  # fh
            fhch_addrs += [H(i, 2) for i in m.back_segs]   # bfh
        flag_segs = [i for i in m.touch_segs if dw.fp_segs_vwh[i][2] is not None]
        blk = bytearray([len(fhch_addrs), len(flag_segs)])
        for a in fhch_addrs:
            blk += _st.pack('<H', a)
        for i in flag_segs:
            blk += _st.pack('<HH', A['hdr'] + i * SEG_HDR_SIZE + SH_FLAGS,
                            A['hdr'] + i * SEG_HDR_SIZE + 12)
        blocks += blk
    out[A['tabl0']] = bytes(ptrs) + bytes(blocks)
    # (TABL2 / private VWH slot lists stripped 2026-07-10: write-only data)
    # CFG
    cfg = bytearray()
    for sec in order:
        m = MOVERS[sec]
        wa, wb = ANIM_WAITS[m.kind]
        sp = _speed88(ANIM_SPEED_WORLD[m.kind])
        if m.kind == 'ceil':
            lo, hi = m.closed, m.open
            start, sst = lo, (0x00 | wa)          # waiting at A (closed)
        else:
            lo, hi = m.bottom, m.top
            start, sst = hi, (0x80 | wb)          # waiting at B (top)
        lo88 = dw._prescale_height(lo) << 8
        hi88 = dw._prescale_height(hi) << 8
        st88 = dw._prescale_height(start) << 8
        cfg += _st.pack('<hhHBBhBB', lo88, hi88, sp, wa, wb, st88, sst, 0)
    out[A['cfg']] = bytes(cfg)
    return out


def install_6502_tables(mem, flat=True):
    for addr, blob in gen_6502_tables(flat).items():
        for i, b in enumerate(blob):
            mem[addr + i] = b


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
    nx, ny = dy / L, -dx / L
    if s[4] == 1:
        nx, ny = -nx, -ny
    if not backside:
        nx, ny = -nx, -ny
    cx, cy = mx + nx * dist, my + ny * dist
    ang = math.atan2(my - cy, mx - cx)
    ab = round(ang * 256 / (2 * math.pi)) & 0xFF
    return int(cx), int(cy), ab
