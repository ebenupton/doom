#!/usr/bin/env python3
"""Generate the cross-language ABI constant files from ONE table.

Every address that crosses a language boundary (ca65 engine <-> beebasm
drivers <-> Python harness/builders) lives HERE and nowhere else. Private
copies of these addresses have shipped three broken-disc bugs (vxc_ab,
the HUD var block, the test-harness pokes) — see project_bank_reshuffle.

Outputs (all checked in; regenerate after editing the table):
  src/abi.inc    ca65   (.if ::BANKED variants where flat differs)
  abi_beeb.inc   beebasm (banked values only — discs are banked builds)
  abi.py         Python  (NAME = banked value; NAME_FLAT where it differs)

Run: python3 tools/gen_abi.py   (from the repo root)
"""
import os
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))

# (name, banked, flat_or_None_if_same_or_meaningless, comment)
ABI = [
    ('BANK_L0',        4,      None, 'legacy alias for BANK_SEG (two-bank re-cut 2026-08-13)'),
    ('BANK_SEG',       4,      None, 'sideways bank A: seg headers+DIRs, verts, recips, VWHC, TABL0 — held for seg stages 1-4'),
    ('BANK_C',         6,      None, 'sideways bank: clipper + rasteriser + HUD'),
    ('BANK_L2',        7,      None, 'legacy alias for BANK_WALK'),
    ('BANK_WALK',      7,      None, 'sideways bank B: node SoA, L8/AE/VATOX, bbox, CPM, rcache, ANIM CFG — held for the whole BSP walk'),
    # Jump tables are GONE (2026-07-16, forbidden): engine entry points
    # (view_setup / render_frame / anim_tick / anim_init / clipper
    # entries) are resolved by SYMBOL from the linker map — beebasm via
    # the generated engine_syms.inc (build_walk_ssd.py), Python via
    # symmap. Only the cfg-anchored region head stays an ABI constant
    # (the driver clear-overlay assert needs it before the engine links).
    ('MAIN_BASE',      0x2A00, None, 'engine CODE region head (cfg-anchored; MAIN first). $2C00 -> $2B00 -> $2A00 2026-08-17 (the second slide came from retiring the LDATA region at $1E00): SSMASK to the freed $1100 page let the driver+PMOVE block slide a page down, so CODE claims $2B00-$2BFF (+256 B of tail slack). Flat matched by moving the CPM psi planes off $2B00.'),
    ('HUD_ENTRY',      0xA400, None, 'hud_draw (bank C window)'),
    # (BCA_WS RETIRED 2026-07-26: the workspace block is gone — the box
    # val[] slots were engine-dead (the classify reads BBP planes; only
    # stale harness pokes touched them) and bca_ab moved to ZP. $1B40-
    # $1BFF is free in both builds and LOW now loads at $1C00.)
    ('BCA_AB',         0x62,   None, 'view angle byte — ZP (zp_buf\'s slot, freed with span_read 2026-07-26; NOT $64 — that is zp_bv_entry\'s HI byte, the drivers seed it); poked per frame by driver/harness; vxc_ab aliases it; zp.inc aliases bca_ab = BCA_AB'),
    ('SQR_BASE',       0x0200, None, 'quarter-square tables: lo,2lo then hi,2hi — one contiguous quad $0200-$05FF, one address, both builds. Moved from $1A00 2026-08-18: pure-function data belongs in the UNSHIPPABLE pages (OS-owned until takeover) — it is GENERATED at boot by the fill at the top of anim_init, never loaded, and the shippable pages it vacated took COLPORT and the pool, killing every boot copy-dance.'),
    # REORDERED 2026-07-12: lo pages CONTIGUOUS (f(0..510) linear), then
    # hi pages — rot_core's frame-constant-mag SMC bases index across the
    # 255 boundary without a window branch. Classic sqr/sqr2 split users
    # are unaffected (the equates still name both windows).
    ('SQR_LO',         'SQR_BASE+$000', None, 'qsqr lo bytes (f 0..255)'),
    ('SQR2_LO',        'SQR_BASE+$100', None, 'qsqr lo bytes (f 256..510)'),
    ('SQRH_BASE',      0x0400, None, 'quarter-square HI pages ($0400/$0500). The 2026-08-09 note about the $0200 staging dance dying is history twice over: the quad is back on the OS pages, but BOOT-GENERATED now, so there is no dance to die.'),
    ('SQR_HI',         'SQRH_BASE+$000', None, 'qsqr hi bytes (f 0..255)'),
    ('SQR2_HI',        'SQRH_BASE+$100', None, 'qsqr hi bytes (f 256..510)'),
    ('DRV_ORG',        0x1E00, None, 'walk/anim driver entry (!BOOT CALLs this). $2000 -> $1F00 -> $1E00 2026-08-17 (RECIP_S left main for bank A, retiring the LDATA region): ANIM_SSMASK vacated $1F00 for the freed $1100 page, so the whole driver + PMOVE block slid one page down and CODE gained $2B00-$2BFF.'),
    ('DRV_VARS',       0x1F80, None, 'walk driver variable block (layout below)'),
    ('DV_ANGIDX',      'DRV_VARS+0',  None, 'view angle index 0..63 (angle byte = idx*4)'),
    ('DV_BACKHI',      'DRV_VARS+1',  None, 'hidden-buffer page hi ($58/$6C)'),
    ('DV_PXF',         'DRV_VARS+2',  None, 'player x 8.8 prescaled, 24-bit: frac'),
    ('DV_PXL',         'DRV_VARS+3',  None, '... int lo'),
    ('DV_PXH',         'DRV_VARS+4',  None, '... int hi'),
    ('DV_PYF',         'DRV_VARS+5',  None, 'player y frac'),
    ('DV_PYL',         'DRV_VARS+6',  None, '... int lo'),
    ('DV_PYH',         'DRV_VARS+7',  None, '... int hi'),
    ('DV_JIDX',        'DRV_VARS+8',  None, 'vsync journal index'),
    ('DV_HUD_EN',      'DRV_VARS+9',  None, 'debug HUD on/off (H toggles)'),
    ('DV_HUD_PREV',    'DRV_VARS+10', None, 'H-key debounce state'),
    ('DRV_GLUE',       0x1FA0, None, 'anim/HUD glue pocket'),
    ('DRV_CLR',        0x2000, None, 'input block + flip scheduler; the unrolled framebuffer clears moved to BANK C 2026-08-16, and the whole driver slid $2200 -> $2100 with DRV_ORG 2026-08-17 (2026-08-14: the sincos overlay moved to bank A $BA00 with STEPTAB/USEVEC; the driver packs below the engine PMOVE region)'),
    ('D_ENABLE',       0x1DFE, None, 'forward-coherence bbox cache master switch'),
    ('D_FWD',          0x1DFF, None, 'per-frame flag: move was forward-only'),
    ('VXC_STATE',      0x0700, None, 'THE BITMAP PAGE: VCACHE_VALID+VDONE+VXC_VALID+RCACHE_COMPUTED (boot zeroes the whole page)'),
    ('VXC_STATE_LEN',  0x100,  None, 'bytes to zero at boot (the whole bitmap page)'),
    ('VXC_ENABLE',     0x1DDB, None, 'translation vertex cache switch (scalars block moved $05xx -> $1Dxx with the sqr swap, same page offsets)'),
    ('RCACHE_STATE',   0xAF00, 0x7268, 'rotation cache header+bitmaps (flat: $F100; carve freed 2026-07-15)'),
    ('RCACHE_STATE_LEN',0x89,  None, 'bytes to zero at boot'),
    ('RCACHE_ENABLE',  0xAF88, 0x72F0, 'rotation-coherence bca cache switch (STATE+$88)'),
    ('CPM_BASE',       0xA600, 0x2900, 'corner-phi memo: 128-slot xor hash, 6 planes. This is the KEY head — 4 key planes, $200 long (the value planes hang off CPM_PSI_BASE, split out flat-side 2026-08-17). Banked $A600 in bank WALK (two-bank re-cut 2026-08-13). SCAR: an earlier home sat ON ROM_BBOX_C and the memo stores SHREDDED the corner planes (black screen after walking; banked gates compare engine-vs-itself so both sides corrupted identically). Scan the MERGED map before claiming space.'),
    ('CPM_KDXL',       'CPM_BASE+$000', None, 'memo key: corner dx lo'),
    ('CPM_KDXH',       'CPM_BASE+$080', None, '... dx hi; DOUBLES as validity: plane ships $80-filled ($80 = impossible dx hi), so there is no EP plane'),
    # The dy key planes split out flat-side 2026-08-17 for the same reason
    # the psi planes did: CODE's head moved down again, to $2A00, and flat
    # has to clear the page. They land on the page RECIP_S vacated when it
    # left main for bank A. Banked keeps the memo contiguous.
    ('CPM_KDY_BASE',   'CPM_BASE+$100', 0x1E00, 'dy key planes head (banked: inline; flat: the page RECIP_S left)'),
    ('CPM_KDYL',       'CPM_KDY_BASE+$000', None, '... dy lo'),
    ('CPM_KDYH',       'CPM_KDY_BASE+$080', None, '... dy hi'),
    # The value planes are addressed independently of the key planes (bca.s
    # indexes each by X), so they need not abut the keys. Split out 2026-08-17
    # so the FLAT memo stops occupying $2B00-$2BFF: CODE's head moved down to
    # $2B00 and flat must match banked below $57FF. Banked keeps them inline.
    ('CPM_PSI_BASE',   'CPM_BASE+$200', 0xD700, 'psi value planes head (banked: inline after the keys; flat: off the $2B00 page CODE took, into the free run above the recip tables)'),
    ('CPM_PSIL',       'CPM_PSI_BASE+$000', None, 'memo value: psi lo'),
    ('CPM_PSIH',       'CPM_PSI_BASE+$080', None, '... psi hi (last plane; the key planes end at CPM_BASE+$200)'),
    # Player-movement collision map (colmap.py, 2026-08-14). Banked =
    # bank WALK free windows (same bank as the node SoA — one paging
    # context for the whole movement test); flat = the TUBE parasite map
    # (the replaced raster pocket $7600-$82FF + the high-table area).
    # colmap.blobs() asserts every blob against these homes.
    ('COLIDX_BASE',    0xAF8A, 0x7600, 'collision blockmap: 36 x (u16 list addr, u8 count) + the u8 lists (banked: $B4A4 -> $AB00 -> $AF8A 2026-08-15 — off the SSMASK staging page, then off the rcache PSI PLANES $A900-$AEFF; now after RCACHE_STATE, ends $B197)'),
    ('COLSEG_BASE',    0xB8C0, 0x7810, 'collision segments: n x 8 (x1,y1,dx,dy raw s16 LE, center-relative)'),
    ('SS_VZ_BASE',     0x8D00, 0xE750, 'per-subsector prescale(floor+41) (s8). Banked $8D00 since 2026-08-19: the fifth of the five adjacent SS planes in bank B ($8900 PC, $8A00 SI, $8B00 FH, $8C00 CH, $8D00 VZ)'),
    # (SS_INFO_BASE retired 2026-08-19: the mover info rides SS_SI bits 5-7 —
    #  idx 0-5, 7 = none; the b7 ceiling flag it carried is per-mover constant
    #  and lives in MV_CEIL)
    ('MV_SS_ID',       0xBFC6, 0xE980, 'mover-subsector probe list: <=8 ids, $FF-padded (pmove scans it twice per move — the 2026-08-19 claw-back that kept SS_PLO plain)'),
    ('MV_SS_INFO',     0xBFCE, 0xE988, 'parallel info bytes, classic SS_INFO format (mover idx, b7 = ceiling)'),
    ('MV_MINPASS',     0xBFC0, 0xE910, 'per-mover min passable door pos (fh + 56, prescaled)'),
    ('COLPORT_BASE',   0x1A00, 0x1A00, 'P_CheckPosition aggregation ports: 42 x 12 (x1,y1,dx,dy s16 + ob_vz + ot_ps + mover + wall-angle). At $1A00 since 2026-08-18 (swapped with the sqr quad): LOW / the tube CODE file load from $1A00, so the ports SHIP DIRECTLY — the staging pages and anim_init copy-down are gone.'),
    ('COL_N_SOLID',    199,    None,   'collision indices >= this are ports (colmap asserts the count)'),
    ('PM_MOMX',        0x1BF8, None,   'player momentum x (s16 8.8 prescaled) — the COLPORT tail; ships as LOW-image zeros (the copy-down that used to zero-seed it is gone)'),
    ('PM_MOMY',        'PM_MOMX+2', None, 'player momentum y (derives — a hard $03FA literal here survived the 2026-08-18 move and cost a red pm_fuzz)'),
    ('PM_TICREM',      0x1BFC, None,   '35Hz tic accumulator remainder — DEAD since single-step momentum; declared for pm_fuzz'),
    ('USETAB_BASE',    0xBE00, 0xE918, 'use + walkover line tables (u8 n, n x 9: x1,y1,dx,dy s16 + action); banked home is BANK A since the slide arc — pmove_use pages SEG for the list reads'),
    ('SCREEN0',        0x5800, 0xEA00, 'framebuffer 0 (flat: harness FB $EA00-$FDFF)'),
    ('SCREEN1',        0x6C00, 0xEA00, 'framebuffer 1 (flat: single buffer)'),
]


def fmt_val(v, hexer):
    if isinstance(v, str):
        return v.replace('$', hexer) if hexer != '$' else v
    return f'{hexer}{v:04X}' if v > 9 else str(v)


HDR = ('GENERATED by tools/gen_abi.py — DO NOT EDIT. One table, three\n'
       'projections: private copies of these addresses are forbidden.')

with open('src/abi.inc', 'w') as f:
    f.write(f'; {HDR.replace(chr(10), chr(10)+"; ")}\n')
    f.write('.ifndef ABI_INC_GUARD\nABI_INC_GUARD = 1\n')
    for name, bank, flat, comment in ABI:
        if flat is None or flat == bank:
            f.write(f'{name} = {fmt_val(bank, "$")}'.ljust(40) + f'; {comment}\n')
        else:
            f.write(f'.if ::BANKED\n{name} = {fmt_val(bank, "$")}'.ljust(40)
                    + f'; {comment}\n.else\n{name} = {fmt_val(flat, "$")}\n.endif\n')
    f.write('.endif\n')

with open('abi_beeb.inc', 'w') as f:
    f.write(f'\\ {HDR.replace(chr(10), chr(10)+chr(92)+" ")}\n')
    f.write('\\ (banked values only: the discs are banked builds)\n')
    for name, bank, flat, comment in ABI:
        f.write(f'{name} = {fmt_val(bank, "&")}'.ljust(40) + f'\\ {comment}\n')

with open('abi.py', 'w') as f:
    f.write(f'# {HDR.replace(chr(10), chr(10)+"# ")}\n')
    env = {}
    for name, bank, flat, comment in ABI:
        v = bank
        if isinstance(v, str):
            v = eval(v.replace('$', '0x'), {}, env)
        env[name] = v
        f.write(f'{name} = 0x{v:04X}  # {comment}\n' if v > 9
                else f'{name} = {v}  # {comment}\n')
        if flat is not None and flat != bank:
            f.write(f'{name}_FLAT = 0x{flat:04X}\n')

print('wrote src/abi.inc, abi_beeb.inc, abi.py')
