#!/usr/bin/env python3
"""Shared banked-image builder (GC 2026-07-12: the rotating spin/modelb
discs are retired — this module survives because build_walk_ssd.py imports
build_images() for the L0/C/L2/LOW bank images and the sincos table).

The animation driver ($3C00) + a 64-frame sincos table ($3E00) are overlaid into
the LOW image (both sit in the clipper-vacated $3C00-$47FF region the render never
touches), so there is NO separate driver file — !BOOT just *SRLOADs the banks,
*LOADs LOW, MODE 4, and jumps to $3C00. SHIFT-BREAK autoboots it."""
import os, subprocess
os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')
os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame; pygame.init()
import doom_wireframe as dw
import fp
from banked_bsp import BankedBspRender, BANK_L0, BANK_C, BANK_L2

SECTOR = 256
TOTAL_SECTORS = 800
SSD_SIZE = TOTAL_SECTORS * SECTOR
import abi
DRV_ADDR = abi.DRV_ORG
N_FRAMES = 64
ANGLE_STEP = 256 // N_FRAMES        # 4


def sincos_table():
    """64 entries x 8 bytes: smag,sneg,sone,cmag,cneg,cone,ab,pad."""
    t = bytearray(N_FRAMES * 8)
    for i in range(N_FRAMES):
        a = (i * ANGLE_STEP) & 0xFF
        sm, sn, so, cm, cn, co = fp.fp_sincos5(a)   # 6502 staging: count-native mag5
        e = i * 8
        t[e+0] = sm & 0xFF
        t[e+1] = 1 if sn else 0
        t[e+2] = 1 if so else 0
        t[e+3] = cm & 0xFF
        t[e+4] = 1 if cn else 0
        t[e+5] = 1 if co else 0
        t[e+6] = a
        t[e+7] = 0
    return bytes(t)


def build_images():
    r = BankedBspRender(dw.packed_layout, dw.packed_rom_main, dw.packed_rom_detail,
                        dw.packed_bbox_table, dw.MAP_CENTER_X, dw.MAP_CENTER_Y, dw.PRESCALE)
    bm = r.bm
    L0 = bytes(bm._banks[BANK_L0]); C = bytes(bm._banks[BANK_C]); L2 = bytes(bm._banks[BANK_L2])
    low_end = 0x2C00 + os.path.getsize('bsp_render_bk.bin')   # CODE region
    low = bytearray(bm[0x1A00:low_end])  # LOW base $1A00 (sqr quad
    # consolidated $1A00-$1DFF + srecip LDATA $1E00 ride the one LOW image, 2026-08-09)
    def overlay(addr, data):
        off = addr - 0x1A00
        low[off:off+len(data)] = data
    drv = open('ANIMDRV', 'rb').read()
    # the engine's PMOVE slice owns $2600-$2BFF (already in the bm slice):
    # a driver that grows past $2600 would overlay-shred it
    assert DRV_ADDR + len(drv) <= 0x2590, \
        f'driver {len(drv)}B reaches the PMOVE slice at $2590'
    overlay(DRV_ADDR, drv)
    # (sincos overlay retired 2026-08-14: the table lives in bank A $BA00
    # with STEPTAB/USEVEC — banked_bsp seeds them into the la image)
    return L0, C, L2, bytes(low)
