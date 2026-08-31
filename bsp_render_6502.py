"""BspRender6502 — wrap span_clip + bsp_render.bin for use by doom_wireframe.

Loads the BSP-traversal/transform 6502 binary alongside span_clip + the
quarter-square tables + the recip table, and exposes a render_frame()
method that runs one frame and returns the framebuffer at $5800.

This is the binary built by bsp_render.asm (BSP walk, vertex transform,
seg processing, span_clip integration) — distinct from the older
Frontend6502 in fe6502.py which uses doom_fe.bin.
"""
import os
from span_clip_6502 import SpanClip6502
from symmap import sym as _sym


# ZP slots used by the engine — resolved from the linked symbol map.
ZP_PX           = _sym('zp_br_px')
ZP_PXH          = _sym('zp_br_px_h')
ZP_PY           = _sym('zp_br_py')
ZP_PYH          = _sym('zp_br_py_h')
ZP_VZ           = _sym('zp_br_vz')
ZP_SMAG         = _sym('zp_br_smag')
ZP_SNEG         = _sym('zp_br_sneg')
ZP_SONE         = _sym('zp_br_sone')
ZP_CMAG         = _sym('zp_br_cmag')
ZP_CNEG         = _sym('zp_br_cneg')
ZP_CONE         = _sym('zp_br_cone')
# Table base pointer slots (absolute RAM — the ZP scavenge moved most of
# them out of ZP; the angle module owns the freed slots).
ZP_PXRAW_LO     = _sym('zp_br_pxraw_l')
ZP_PXRAW_HI     = _sym('zp_br_pxraw_h')
ZP_PYRAW_LO     = _sym('zp_br_pyraw_l')
ZP_PYRAW_HI     = _sym('zp_br_pyraw_h')

ENTRY_BR_VIEW_SETUP   = _sym('view_setup')
ENTRY_BR_RENDER_FRAME = _sym('render_frame')

# Table load addresses: harness-owned placement decisions (the engine reads
# these tables only through the pointer slots above), NOT engine symbols.
ROM_MAIN_BASE   = 0x8600
                           # mover slots (1248 total) overflowed the old slot below
                           # ANG at $E940; $FB00-$FFF9 is unused in the flat harness.
                           # $E484-$E93F now hosts the flat ANIM tables + workers.
ROM_DETAIL_BASE = 0xB900
# flat bases (KEEP IN SYNC with src/layout.inc flat branch; 2026-07-21 map):
ROM_SEG_HDR_BASE = 0x8600       # stride-18 headers, heights at +12..17
ROM_VERTS_BASE   = 0xB100
NODE_SOA_BASE    = 0xB900       # node/ss SoA pages
ROM_BBOX_BASE   = 0xC500   # 16 corner planes $C500-$D4FF (page-split SoA)
                           # build/split the bbox pointer byte-at-a-time


def _mem_banked(mem):
    """Is this a banked rig's memory?  BankedMemory models the $8000-$BFFF
    window; a plain list is the flat image.  Symbol lookups below MUST
    follow it -- resolving flat addresses against a banked rig poked the
    vrcache-valid clear into the wrong place (the walk then saw stale
    'done' state and visited ZERO subsectors) and left OBJ_ANYB non-zero
    so objects drew into an objects-off differential.  2026-08-30."""
    return type(mem).__name__ == 'BankedMemory'


def poke_init_frame_state(mem):
    """Mirror render_frame's inline per-frame init for partial-flow
    harnesses (the standalone jt_br_init_frame entry retired 2026-07-15):
    records-pointer ground state + the 60-byte vrcache valid clear."""
    # VRCACHE_VALID + VDONE ride separate VXCACHE plane tails since
    # 2026-08-13 (57 B each) — wipe both by symbol
    _bk = 1 if _mem_banked(mem) else 0
    for name in ('VRCACHE_VALID_BASE', 'VDONE'):
        base = _sym(name, banked=_bk)
        for i in range(57):
            mem[base + i] = 0


def disable_objects(mem):
    """Zero the OBJ_ANYB per-subsector bitmap: no subsector tests positive,
    so the engine neither stamps billboards nor tightens behind them.
    For FB-compare harnesses whose python reference does not model objects
    (the documented OBJ_DRAW reference gap). Call AFTER any init that runs
    obj_anyb_fill (anim_init refills the bitmap from OBJ_BITS)."""
    from symmap import sym as _sym2
    _anyb = _sym2('OBJ_ANYB', banked=1 if _mem_banked(mem) else 0)
    for i in range(28):
        mem[_anyb + i] = 0


class BspRender6502:
    """Persistent BSP-render 6502 instance for interactive use."""

    def __init__(self, packed_layout, packed_rom_main, packed_rom_detail,
                 packed_bbox_table, map_center_x=1200, map_center_y=-3250,
                 prescale=8):
        self.layout = packed_layout
        self.rom_main = packed_rom_main
        self.rom_detail = packed_rom_detail
        self.bbox_table = packed_bbox_table
        self.map_center_x = map_center_x
        self.map_center_y = map_center_y
        self.prescale = prescale
        self.last_cycles = 0

        self.sc = SpanClip6502()
        self._load_wad()

    def _load_wad(self):
        from wad_packed import SEG_DTL_SIZE, SD_FH, SD_CH, SD_BFH, SD_BCH

        layout = self.layout
        rom_main = self.rom_main
        rom_detail = self.rom_detail
        bbox = self.bbox_table
        mem = self.sc.mpu.memory

        # Flat placement (2026-07-11, heights inlined in the seg headers):
        # headers $6C00-$9B8B, verts $9C00, node/ss SoA $B600 (the hole the
        # retired FHCH stream vacated). The packer bakes the height bytes
        # (former load-time FHCH synthesis) into the header at +10..13.
        off_verts = layout['off_verts']; off_hdr = layout['off_seg_hdr']
        for i in range(off_verts):                       # SoA pages (14: 11 node + 3 ss)
            mem[NODE_SOA_BASE + i] = rom_main[i]
        # SS_PG rebase (2026-08-29): the loaded plane carries the FINAL
        # header hi byte (+>ROM_SEG_HDR_BASE); rom_main keeps the raw page
        for i in range(layout['n_ss']):
            _pgoff = layout['off_ss'] + i
            mem[NODE_SOA_BASE + _pgoff] = (rom_main[_pgoff] + (ROM_SEG_HDR_BASE >> 8)) & 0xFF
        for i in range(off_verts, off_hdr):              # verts
            mem[ROM_VERTS_BASE + (i - off_verts)] = rom_main[i]
        off_obj = layout['off_obj']
        # header blob ends at off_ss_cnt: the SS_CNT plane (PG/CNT split
        # 2026-08-29) is the rom_main TAIL with its OWN home — the blob
        # copy must NOT extend past $A3FF (RC_PH_0 owns flat $A400)
        off_ss_cnt = layout['off_ss_cnt']
        for i in range(off_hdr, off_ss_cnt):             # headers + DIRs
            mem[ROM_SEG_HDR_BASE + (i - off_hdr)] = rom_main[i]
        from symmap import sym as _symc
        _cntb = _symc('ROM_SS_CNT_C')
        for i in range(256):                             # SS_CNT plane
            mem[_cntb + i] = rom_main[off_ss_cnt + i]
        # static-object (billboard) table -- its own home, NOT part of the
        # header blob (layout.inc ROM_OBJ_C). The art templates have a
        # PER-BUILD home (2026-08-27: the flat hole is only 256 bytes --
        # colmap's USEVEC owns $B800 -- so flat art lives at $E830).
        from symmap import sym as _sym2
        _ob = _sym2('ROM_OBJ_C')
        off_art = layout['off_obj_art']              # at the rom_main TAIL
        # FLAT KEEPS THE LEGACY SUBSET (2026-08-31): the pickup landing
        # took the pack to 60+, whose planes outgrow the 256-byte $B700
        # run, and no honest flat hole exists.  GATHER the kind<=1 subset
        # (barrel/lamp; the pillar died 2026-08-31) into a 16-wide SoA
        # with a rebuilt bitmap; a subset of the ss-sorted pack stays
        # ss-sorted.
        _n62 = layout['n_obj']
        _keep = [i for i in range(_n62)
                 if rom_main[off_obj + 4 * _n62 + i] <= 1][:14]
        assert len(_keep) == 14, f'flat expected 14 legacy objects, got {len(_keep)}'
        for _pl in range(7):
            for _j, _i in enumerate(_keep):
                mem[_ob + _pl * 14 + _j] = rom_main[off_obj + _pl * _n62 + _i]
        for _j in range(layout['obj_bits_len']):
            mem[_ob + 7 * 14 + _j] = 0
        # RUN8 sits AFTER the 25-byte bitmap (OBJ_RUN8 = OBJ_BITS +
        # LAY_OBJ_BITS_LEN), NOT at 8*n_obj -- the original 8*n form
        # overlapped the bitmap and left the engine reading garbage run
        # starts, which sent obj_scan/obj_project off into the weeds and
        # made EVERY flat render a silent 500k-step runaway (the 'flat
        # harness is blind' mystery, the SQR_MIRROR BRK spray).  The
        # stack guard caught it the day it was written.
        _r8 = _ob + 7 * 14 + layout['obj_bits_len']
        for _j in range(layout['obj_bits_len']):
            mem[_r8 + _j] = 0xFF                 # RUN8, subset-rebuilt
        for _j, _i in enumerate(_keep):
            _ss = rom_main[off_obj + 3 * _n62 + _i]
            mem[_ob + 7 * 14 + (_ss >> 3)] |= 1 << (_ss & 7)
            if mem[_r8 + (_ss >> 3)] == 0xFF:
                mem[_r8 + (_ss >> 3)] = _j
        _oa = _sym2('OBJ_ART')
        _na = 4 * layout['n_obj_art']                # EXACT length: the flat
        for i in range(off_art, off_art + _na):      # home abuts colmap's
            mem[_oa + (i - off_art)] = rom_main[i]   # minpass/usetab -- the
                                                     # hole's zero tail must
                                                     # NOT be copied with it
        # LV1 BKT planes + per-dir DBOUND — per-build homes, from the
        # blob tail (see layout.inc ROM_BKTLO/HI_C, ROM_DBOUND_C)
        for _nm, _off in (('ROM_BKTLO_C', layout['off_bktlo']),
                          ('ROM_BKTHI_C', layout['off_bkthi']),
                          ('ROM_DBOUND_C', layout['off_dbound'])):
            _d = _sym2(_nm)
            for i in range(128):
                mem[_d + i] = rom_main[_off + i]
        # OBJ_ANYB: the main-RAM bitmap the inline per-subsector probe reads
        # (hardware fills it from anim_init; harness renders may never run
        # that, so poke it here — the sqr_fill dual-path pattern)
        _anyb = _sym2('OBJ_ANYB')
        # flat OBJ_ANYB mirrors the GATHERED bitmap at ROM_OBJ_C + 7*16
        for i in range(layout['obj_bits_len']):
            mem[_anyb + i] = mem[_ob + 7 * 14 + i]

        for i, b in enumerate(bbox):
            mem[ROM_BBOX_BASE + i] = b

        # vertex-span descriptor tables (flat homes: bsp/header.s equates)
        import doom_wireframe as dw
        for i, d in enumerate(dw.vspan_desc):
            mem[0xDC00 + i] = d
        for i, (lo, hi, cont) in enumerate(dw.vspan_expl):
            _lo, _hi, _ct = dw.vexpl_bytes(i, lo, hi, cont)
            mem[0xDE00 + i] = _lo            # H2 jamb entries bake half-unit
            mem[0xDE80 + i] = _hi            # bounds + CONT bit 7 (2026-08-25)
            mem[0xDF00 + i] = _ct

        def w16(addr_lo, val):
            mem[addr_lo]     = val & 0xFF
            mem[addr_lo + 1] = (val >> 8) & 0xFF

        # Angle-space bbox module + tables (rebuilds first — a standalone run
        # after a source edit must not test a stale bin).
        from engine_load import load_angle_module
        load_angle_module(mem)
        # CANARY (2026-08-29): load_angle_module RELOADS every flat region
        # file — any poked table a region overlaps gets silently replaced
        # by code bytes. The dbound stomp read as +0.35% MEAN and a
        # walkseq pixel flip before this tripped anything.
        for _nm, _off in (('ROM_BKTLO_C', layout['off_bktlo']),
                          ('ROM_BKTHI_C', layout['off_bkthi']),
                          ('ROM_DBOUND_C', layout['off_dbound'])):
            _d = _sym2(_nm)
            for i in (0, 64, 127):
                assert mem[_d + i] == rom_main[_off + i], \
                    f'{_nm} stomped by a region reload (engine code grew over it?)'

    def render_frame(self, player_x, player_y, angle_byte, floor_z=0):
        import fp
        sc = self.sc
        mem = sc.mpu.memory

        px_88 = int((player_x - self.map_center_x) * 256 / self.prescale)
        py_88 = int((player_y - self.map_center_y) * 256 / self.prescale)
        mem[ZP_PX]     = px_88 & 0xFF
        mem[ZP_PXH] = (px_88 >> 8) & 0xFF
        mem[ZP_PY]     = py_88 & 0xFF
        mem[ZP_PYH] = (py_88 >> 8) & 0xFF
        # s16 integer position: high bytes (whole-map support, not just
        # +/-127 prescaled units around MAP_CENTER)
        mem[_sym('zp_br_px_x')] = (px_88 >> 16) & 0xFF
        mem[_sym('zp_br_py_x')] = (py_88 >> 16) & 0xFF

        # Eye height (pre-scaled, s8). doom_wireframe normally does
        # vz = prescale_height(player_floor + 41); we get player_floor in.
        # Inline a minimal prescale_height.
        ASPECT_NUM = 6; ASPECT_DEN = 5
        vz = ((floor_z + 41) * ASPECT_NUM + (self.prescale * ASPECT_DEN) // 2) \
             // (self.prescale * ASPECT_DEN)
        mem[ZP_VZ] = vz & 0xFF

        # raws mirror pmf_cand EXACTLY (2026-08-26): position quantized
        # to 8.8 prescaled, raw = FLOOR (the old int() truncation and
        # trace_compare's round() were unfaithful at fractional poses),
        # plus the world-frac bytes and the tie-broken doubled pairs the
        # exact node point-on-side consumes.
        _px88 = int((player_x - self.map_center_x) * 256 / self.prescale)
        _py88 = int((player_y - self.map_center_y) * 256 / self.prescale)
        raw_px, raw_py = _px88 >> 5, _py88 >> 5
        _fx, _fy = (_px88 << 3) & 0xFF, (_py88 << 3) & 0xFF
        mem[ZP_PXRAW_LO]     = raw_px & 0xFF
        mem[ZP_PXRAW_HI] = (raw_px >> 8) & 0xFF
        mem[ZP_PYRAW_LO]     = raw_py & 0xFF
        mem[ZP_PYRAW_HI] = (raw_py >> 8) & 0xFF
        from symmap import sym as _sy
        mem[_sy('PM_FXW')], mem[_sy('PM_FXW') + 2] = _fx, _fy
        _px2 = (raw_px << 1) | (1 if _fx else 0)
        _py2 = (raw_py << 1) | (1 if _fy else 0)
        mem[_sy('zp_br_px2_l')] = _px2 & 0xFF
        mem[_sy('zp_br_px2_h')] = (_px2 >> 8) & 0xFF
        mem[_sy('zp_br_py2_l')] = _py2 & 0xFF
        mem[_sy('zp_br_py2_h')] = (_py2 >> 8) & 0xFF

        s_mag, s_neg, s_one, c_mag, c_neg, c_one = fp.fp_sincos(angle_byte)
        mem[ZP_SMAG] = s_mag
        mem[ZP_SNEG] = 1 if s_neg else 0
        mem[ZP_SONE] = 1 if s_one else 0
        mem[ZP_CMAG] = c_mag
        mem[ZP_CNEG] = 1 if c_neg else 0
        mem[ZP_CONE] = 1 if c_one else 0
        mem[_sym('bca_ab')] = angle_byte & 0xFF  # angle-space bbox view angle

        sc._run(ENTRY_BR_VIEW_SETUP)
        sc.init()
        sc.clear_screen()
        cyc = sc._run(ENTRY_BR_RENDER_FRAME, max_cycles=10000000)
        self.last_cycles = cyc
        return cyc

    def blit_framebuffer_to(self, surface):
        """Render the 256x160 BBC mode-4 framebuffer into `surface`.

        The base is the harness's own SCREEN_START -- flat parks the FB at
        $EA00 (out of the shared <32K map), banked uses the real hardware
        screen at $5800.  Hardcoding $EA00 here made every banked frame
        read as blank (2026-08-29).
        """
        import pygame
        mem = self.sc.mpu.memory
        start = getattr(self.sc, 'SCREEN_START', 0xEA00)
        surface.fill((0, 0, 0))
        pix = pygame.PixelArray(surface)
        for cy in range(20):
            for col in range(32):
                for pr in range(8):
                    y = cy * 8 + pr
                    if y >= surface.get_height():
                        break
                    byte = mem[start + cy * 256 + col * 8 + pr]
                    for bit in range(8):
                        if byte & (0x80 >> bit):
                            pix[col * 8 + bit, y] = (255, 255, 255)
        del pix
