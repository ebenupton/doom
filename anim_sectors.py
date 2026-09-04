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
from wad_packed import (SEG_DTL_SIZE, SEG_HDR_SIZE, seg_hdr_off, SH_BPAL,
                        SD_FH, SD_CH, SD_BFH,
                        SD_BCH, SH_FLAGS, SF_SOLID, SF_NEEDBT, SF_NEEDBB,
                        SF_STEPUP_T, SF_STEPUP_B)

_LAYOUT = dw.packed_layout
_ROM_MAIN = dw.packed_rom_main          # bytearray — shared with _p_rom_main
_ROM_DETAIL = dw.packed_rom_detail
_OFF_SEG_HDR = _LAYOUT['off_seg_hdr']
_SS_FH_REL = _LAYOUT['off_ss_fh'] - _OFF_SEG_HDR     # front-height pages,
_SS_CH_REL = _LAYOUT['off_ss_ch'] - _OFF_SEG_HDR     #  relative to the base
_BPAL_REL = _LAYOUT['off_bpal'] - _OFF_SEG_HDR       # back-pair palette page


def _bpal_id(i):
    """The seg's back-pair palette id. Mover-touching segs hold PRIVATE
    entries (wad_packed), which is what makes patching one safe."""
    return _ROM_MAIN[_OFF_SEG_HDR + seg_hdr_off(i) + SH_BPAL]


def _seg_ss():
    """slot -> subsector id (front heights are per SUBSECTOR since
    2026-08-17, so a mover patches its subsectors, not its segs)."""
    m = {}
    for ssi, (cnt, first) in enumerate(dw.fp_ssectors):
        for j in range(first, first + cnt):
            m[j] = ssi
    return m

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
        self.touch_segs = sorted(
            i for i in set(self.front_segs) | set(self.back_segs)
            if i in _seg_to_ss)     # drop page-slotting pad clones
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
                if self.sec in USE_DOORS:
                    return                # DOOM DR door: shut until used
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
        _ss_of = _seg_ss()
        _touched_ss = set()
        for i in self.front_segs:
            o = i * SEG_DTL_SIZE
            _ROM_DETAIL[o + SD_FH] = fh_ps & 0xFF
            _ROM_DETAIL[o + SD_CH] = ch_ps & 0xFF
            one_sided = dw.fp_segs_vwh[i][2] is None
            # front heights: ONE write per subsector, not per seg
            ssi = _ss_of.get(i)
            if ssi is not None and ssi not in _touched_ss:
                _touched_ss.add(ssi)
                _ROM_MAIN[_OFF_SEG_HDR + _SS_FH_REL + ssi] = fh_ps & 0xFF
                _ROM_MAIN[_OFF_SEG_HDR + _SS_CH_REL + ssi] = ch_ps & 0xFF
                for mem, base in _attached:
                    mem[base['seg_hdr'] + _SS_FH_REL + ssi] = fh_ps & 0xFF
                    mem[base['seg_hdr'] + _SS_CH_REL + ssi] = ch_ps & 0xFF
                nbytes += 2
            if one_sided:
                # the palette entry carries the fh/ch alias for a one-sided
                # seg (descriptor scheme, no runtime branch) and must track
                _e = _BPAL_REL + _bpal_id(i)
                _ROM_MAIN[_OFF_SEG_HDR + _e + 0x00] = fh_ps & 0xFF
                _ROM_MAIN[_OFF_SEG_HDR + _e + 0x80] = ch_ps & 0xFF
                for mem, base in _attached:
                    mem[base['seg_hdr'] + _e + 0x00] = fh_ps & 0xFF
                    mem[base['seg_hdr'] + _e + 0x80] = ch_ps & 0xFF
                nbytes += 2
        # HALF-UNIT tier (2026-08-25): every back-pair representation
        # carries half-prescaled bytes (the packer bakes 2h; the 6502
        # patcher writes pos>>7). This python patcher is integer-driven
        # (floor/ceil are rounded world heights), so its half value is
        # 2x the integer — python-attached runs stay at integer poses
        # by construction, coherent with the packed-python normalizer.
        fh2_ps, ch2_ps = (fh_ps * 2) & 0xFF, (ch_ps * 2) & 0xFF
        for i in self.back_segs:
            o = i * SEG_DTL_SIZE
            _ROM_DETAIL[o + SD_BFH] = fh2_ps
            _ROM_DETAIL[o + SD_BCH] = ch2_ps
            _e = _BPAL_REL + _bpal_id(i)
            _ROM_MAIN[_OFF_SEG_HDR + _e + 0x00] = fh2_ps
            _ROM_MAIN[_OFF_SEG_HDR + _e + 0x80] = ch2_ps
            for mem, base in _attached:
                mem[base['seg_hdr'] + _e + 0x00] = fh2_ps
                mem[base['seg_hdr'] + _e + 0x80] = ch2_ps
            nbytes += 2
        # seg flags: re-derive SOLID/NEEDBT/NEEDBB (the packer's rules)
        for i in self.touch_segs:
            sv = dw.fp_segs_vwh[i]
            fi, bi = sv[1], sv[2]
            if bi is None:
                continue
            ffh, fch = dw.fp_sectors[fi][0], dw.fp_sectors[fi][1]
            bfh, bch = dw.fp_sectors[bi][0], dw.fp_sectors[bi][1]
            o = _OFF_SEG_HDR + seg_hdr_off(i) + SH_FLAGS
            f = _ROM_MAIN[o] & ~(SF_SOLID | SF_NEEDBT | SF_NEEDBB
                                 | SF_STEPUP_T | SF_STEPUP_B)
            if bch <= ffh or bfh >= fch:
                f |= SF_SOLID
            else:
                if bch < fch: f |= SF_NEEDBT
                if bfh > ffh: f |= SF_NEEDBB
                if bch > fch: f |= SF_STEPUP_T
                if bfh < ffh: f |= SF_STEPUP_B
            _ROM_MAIN[o] = f
            for mem, base in _attached:
                mem[base['seg_hdr'] + seg_hdr_off(i) + SH_FLAGS] = f
            nbytes += 1
        # jamb explicit vspans (in-plane door/lift junctions): the MOVING
        # bound of the entry tracks the mover so the jamb edge grows and
        # shrinks with it (doom_wireframe ANIM_JAMB; the 6502 mirrors via
        # the anim worker's VEXPL patch list). Flat homes $DE00/$DE80
        # match bsp_render_6502's installer.
        for ix, role in dw.ANIM_JAMB.get(sec, ()):
            lo, hi, cont = dw.vspan_expl[ix]
            if role == 'hi':
                dw.vspan_expl[ix] = (lo, ch_ps, cont)
            else:
                dw.vspan_expl[ix] = (fh_ps, hi, cont)
            for mem, base in _attached:
                if role == 'hi':
                    mem[0xDE80 + ix] = ch_ps & 0xFF   # VEXPL: integer tier
                else:
                    mem[0xDE00 + ix] = fh_ps & 0xFF
            nbytes += 1
        STATS['bytes'] += nbytes

    def trigger_use(self):
        """DOOM DR use semantics (mirrors pmove_use): waiting -> move away
        from the held end; moving -> reverse."""
        if self.state == 'wait_closed':
            self.state = 'opening'
        elif self.state == 'wait_open':
            self.state = 'closing'
        elif self.state == 'opening':
            self.state = 'closing'
        elif self.state == 'closing':
            self.state = 'opening'

    # ── scripted access (demo strips) ────────────────────────────────
    def phase(self, t):
        """t=0 rest/closed .. t=1 fully open/lowered; applies eagerly."""
        if self.kind == 'ceil':
            self.pos = self.closed + t * (self.open - self.closed)
        else:
            self.pos = self.top + t * (self.bottom - self.top)
        self.flush()


# ── seg -> subsector membership. Built BEFORE the movers: page-slotting
# pads the header array with clones that belong to NO subsector run
# (never rendered, never revealed) — every mover seg scan must ignore
# those slots, so Mover.__init__ filters touch_segs through this map.
_seg_to_ss = {}
for _ssi, (_cnt, _first) in enumerate(dw.fp_ssectors):
    for _k in range(_first, _first + _cnt):
        _seg_to_ss[_k] = _ssi

MOVERS = {sec: Mover(sec) for sec in dw.ANIM_SECTORS}

# H2 bound assert (2026-08-25): the 6502 flag worker compares mover quads
# with PLAIN SBC sign tests after doubling the integer side — every
# doubled diff must stay inside s8 over the mover's WHOLE travel. The
# diff is monotone in pos, so the two travel endpoints suffice.
for _m in MOVERS.values():
    _ends = ((_m.closed, _m.open) if _m.kind == 'ceil'
             else (_m.bottom, _m.top))
    for _i in _m.touch_segs:
        _sv = dw.fp_segs_vwh[_i]
        _fi = _sv[1] if _sv[1] != _m.sec else _sv[2]
        if _fi is None:
            continue
        _ffh = dw._prescale_height(dw.sectors[_fi][0])
        _fch = dw._prescale_height(dw.sectors[_fi][1])
        for _e in _ends:
            _ep = dw._prescale_height(_e)
            for _d in (2 * _ep - 2 * _ffh, 2 * _ep - 2 * _fch):
                assert -128 <= _d <= 127, \
                    f'H2 flag diff {_d} overflows s8 (mover {_m.sec} seg {_i})'

# ── subsector -> movers mask (which movers a visited ss can reveal) ─────
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

# Calibrated to the 50Hz FIELD tick (2026-08-21 — the values below were
# per-frame numbers from the pre-beam-clock era; after the field-locked
# T1 arc made anim_tick run per PAL field, doors snapped open in 6
# fields and held for 0.4s: 'doors have been broken for some time').
# Speeds mirror the python MOVERS spec: DOOR_SPEED 140, LIFT_SPEED 120
# world units/second -> /50 per field.
ANIM_SPEED_WORLD = {'ceil': 140 / 50, 'floor': 120 / 50}  # world u / field
# Waits in units of FOUR fields (anim_tick's /4 wait prescaler — the
# 6-bit timer can't hold multi-second waits in raw fields). Mirrors the
# MOVERS spec: door closed 1.6s/open 2.2s; lift bottom 1.4s/top 2.0s.
ANIM_WAITS = {'ceil': (20, 28), 'floor': (18, 25)}  # 4-field units at A, B


def _use_doors():
    """Movers with a DR (special 1) use line: DOOM doors — idle SHUT
    until SPACE (wait_at_A = 0 = the hold-forever sentinel; pmove_use /
    Mover.trigger_use start them). Walkover movers keep auto-cycling
    until walk triggers are wired."""
    out = set()
    for ld in dw.linedefs:
        if ld[3] == 1:
            for sd in (ld[5], ld[6]):
                if sd != 0xFFFF and dw.sidedefs[sd][5] in dw.ANIM_SECTORS:
                    out.add(dw.sidedefs[sd][5])
    return out


USE_DOORS = _use_doors()


def _speed88(world_per_frame):
    # world/field -> prescaled 8.8 per field (per-field speeds are
    # fractional world units since the 50Hz calibration: int-round)
    return max(1, int(round(dw._prescale_height(world_per_frame * 256))))


def gen_6502_tables(flat=True):
    """{address: bytes} for the flat harness or the banked window space."""
    import struct as _st
    if flat:
        # THE PARASITE MAP (2026-09-02): flat homes = banked homes laid
        # flat; every address comes from the flat symbol map, so the two
        # builds cannot drift.
        import symmap as _sm
        _f = lambda n: _sm.sym(n, banked=0)
        A = dict(ssmask=_f('ANIM_SSMASK'), tabl0=_f('ANIM_TABL0'),
                 cfg=_f('ANIM_CFG'), hdr=_f('ROM_SEG_HDR_C'),
                 vex_lo=_f('VEXPL_LO'), vex_hi=_f('VEXPL_HI'),
                 ss_fh=_f('ROM_SS_FH_C'), ss_ch=_f('ROM_SS_CH_C'),
                 # BY THE MAP like the banked arm: the header-relative
                 # fallback shipped BPAL patch pointers at the DEAD $7500
                 # emitter home -- caught by the pure-concat gate
                 # 2026-09-02, the same class as the banked broken-doors
                 # bug this dict's own comment records.
                 bpal=_f('BPAL_BASE'))
    else:
        # banked ss_fh/ss_ch BY THE MAP (the five SS planes live in bank B
        # since 2026-08-19, no longer header-relative) — today's five
        # stale-literal reds are why this is symmap, not a number
        import symmap as _sm
        _b = lambda n: _sm.sym(n, banked=1)      # BY THE MAP, no literals:
        # vex_lo/vex_hi drifted to $A700/$A780 after the 2026-09-02 bank-C
        # compaction pulled VEXPL down to $A100/$A180 -- and $A700 now sits
        # INSIDE the rasteriser code, so the jamb patcher was corrupting
        # RASTER_ENTRY (anim6502_check stack-imbalance crash).  Symbol-driven
        # now, like the flat branch.
        A = dict(ssmask=_b('ANIM_SSMASK'), tabl0=_b('ANIM_TABL0'),
                 cfg=_b('ANIM_CFG'), hdr=_b('ROM_SEG_HDR_C'),
                 vex_lo=_b('VEXPL_LO'), vex_hi=_b('VEXPL_HI'),
                 ss_fh=_b('ROM_SS_FH_C'),
                 ss_ch=_b('ROM_SS_CH_C'),
                 # BPAL is NOT header-relative in the banked map: the
                 # seg-header squeeze moved it to the top of bank A. The
                 # header-relative form silently pointed the mover back-
                 # pair patches at $9Dxx — free space at first, VXCACHE
                 # once the caches moved in: THE broken-doors bug
                 # (2026-08-19..21, census-invisible to every gate).
                 bpal=_sm.sym('BPAL_BASE', banked=1))
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
        # back pair: the PALETTE entry for this seg (private for movers)
        _bpal_base = A['bpal']              # BY THE MAP, both builds (the
                                            # hdr-relative fallback is DEAD:
                                            # it aimed movers' back-pair
                                            # patches at freed RAM)
        B = lambda i, k: _bpal_base + (0x80 if k else 0x00) + _bpal_id(i)
        ss_of = _seg_ss()
        solid = lambda i: dw.fp_segs_vwh[i][2] is None
        seen_ss = set()
        def front_ss(segs, base):
            out = []
            for i in segs:
                ssi = ss_of.get(i)
                if ssi is None or (ssi, base) in seen_ss:
                    continue
                seen_ss.add((ssi, base))
                out.append(base + ssi)
            return out
        # SPLIT LISTS since 2026-08-19: front-page addrs (bank B) first,
        # back-pair addrs (bank A BPAL) second — the worker flips banks
        # between the two phases
        if m.kind == 'ceil':
            front_addrs = front_ss(m.front_segs, A['ss_ch'])   # ch (per ss)
            back_addrs = [B(i, 1) for i in m.back_segs]        # bch
            # SOLID front segs (the mover's own side walls): the back slot is
            # the descriptor-scheme alias (bch := ch) and must track too
            back_addrs += [B(i, 1) for i in m.front_segs if solid(i)]
        else:
            front_addrs = front_ss(m.front_segs, A['ss_fh'])   # fh (per ss)
            back_addrs = [B(i, 0) for i in m.back_segs]        # bfh
            back_addrs += [B(i, 0) for i in m.front_segs if solid(i)]
        flag_segs = [i for i in m.touch_segs if dw.fp_segs_vwh[i][2] is not None]
        # jamb VEXPL patch targets: the entry byte holding the MOVING bound
        # (bank C banked — the worker pages around these writes)
        vexpl_addrs = [(A['vex_hi'] if role == 'hi' else A['vex_lo']) + ix
                       for ix, role in dw.ANIM_JAMB.get(sec, ())]
        # Census guard (the tube lesson, twice now): every patch address
        # must land inside a KNOWN plane. Banked: front -> bank-B SS
        # pages, back -> the BPAL page. Anything else is a stale base.
        if not flat:
            for a in front_addrs:
                assert (A['ss_fh'] & 0xFF00) <= a <= (A['ss_ch'] | 0xFF), \
                    f'front patch addr {a:#x} outside the SS planes'
            for a in back_addrs:
                assert (_bpal_base & 0xFF00) <= a <= (_bpal_base | 0xFF), \
                    f'back patch addr {a:#x} outside the BPAL page'
        blk = bytearray([len(front_addrs), len(back_addrs),
                         len(flag_segs), len(vexpl_addrs)])
        for a in front_addrs + back_addrs:
            blk += _st.pack('<H', a)
        # flag entries: the height quad is no longer contiguous — fh/ch sit on
        # the per-subsector pages (ch = fh + $100 always). The BACK pair is in
        # the same header as the flags byte, so the worker derives its address
        # (+SH_BFH-SH_FLAGS) instead of us spending 2 more bytes per entry:
        # TABL0's budget is 252 B and 6-byte entries overflowed it into the
        # CFG table, silently — see the assert below.
        for i in flag_segs:
            blk += _st.pack('<HH', A['hdr'] + seg_hdr_off(i) + SH_FLAGS,
                            A['ss_fh'] + ss_of[i])
        for a in vexpl_addrs:
            blk += _st.pack('<H', a)
        blocks += blk
    _t0 = bytes(ptrs) + bytes(blocks)
    # HARD budget (this bit once): banked TABL0 sits at $BE90 with ANIM_TABL0's
    # 252 B ahead of the bank tail, flat at $E600 with ANIM_CFG at $E700. An
    # oversized blob does not fail here, it CORRUPTS the next table and the
    # worker then reads garbage counts.
    assert len(_t0) <= 252, \
        f'TABL0 blob {len(_t0)} B exceeds its 252 B budget (would run into CFG)'
    out[A['tabl0']] = _t0
    # (TABL2 / private VWH slot lists stripped 2026-07-10: write-only data)
    # CFG
    cfg = bytearray()
    for sec in order:
        m = MOVERS[sec]
        wa, wb = ANIM_WAITS[m.kind]
        if sec in USE_DOORS:
            wa = 0                        # hold shut until used
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
