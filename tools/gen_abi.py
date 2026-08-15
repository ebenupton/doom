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
    ('MAIN_BASE',      0x2C00, None, 'engine CODE region head (cfg-anchored; MAIN first)'),
    ('HUD_ENTRY',      0xA400, None, 'hud_draw (bank C window)'),
    # (BCA_WS RETIRED 2026-07-26: the workspace block is gone — the box
    # val[] slots were engine-dead (the classify reads BBP planes; only
    # stale harness pokes touched them) and bca_ab moved to ZP. $1B40-
    # $1BFF is free in both builds and LOW now loads at $1C00.)
    ('BCA_AB',         0x62,   None, 'view angle byte — ZP (zp_buf\'s slot, freed with span_read 2026-07-26; NOT $64 — that is zp_bv_entry\'s HI byte, the drivers seed it); poked per frame by driver/harness; vxc_ab aliases it; zp.inc aliases bca_ab = BCA_AB'),
    ('SQR_BASE',       0x1A00, None, 'quarter-square tables, CONSOLIDATED $1A00-$1DFF 2026-08-09 (the retired vsync-journal page + the freed VCACHE_VALID page): lo,2lo then hi,2hi — one contiguous quad, one address, both builds'),
    # REORDERED 2026-07-12: lo pages CONTIGUOUS (f(0..510) linear), then
    # hi pages — rot_core's frame-constant-mag SMC bases index across the
    # 255 boundary without a window branch. Classic sqr/sqr2 split users
    # are unaffected (the equates still name both windows).
    ('SQR_LO',         'SQR_BASE+$000', None, 'qsqr lo bytes (f 0..255)'),
    ('SQR2_LO',        'SQR_BASE+$100', None, 'qsqr lo bytes (f 256..510)'),
    ('SQRH_BASE',      0x1C00, None, 'quarter-square HI pages ($1C00/$1D00) — UNFORKED into the $1A00-$1DFF quad 2026-08-09: the $0200 OS-page boot-staging dance died (page 2 freed — the tube client owns it); flat $1E00 freed for LDATA'),
    ('SQR_HI',         'SQRH_BASE+$000', None, 'qsqr hi bytes (f 0..255)'),
    ('SQR2_HI',        'SQRH_BASE+$100', None, 'qsqr hi bytes (f 256..510)'),
    ('DRV_ORG',        0x2000, None, 'walk/anim driver entry (!BOOT CALLs this)'),
    ('DRV_VARS',       0x2180, None, 'walk driver variable block (layout below)'),
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
    ('DRV_GLUE',       0x21A0, None, 'anim/HUD glue pocket'),
    ('DRV_CLR',        0x2200, None, 'unrolled clears + input block (2026-08-14: the sincos overlay moved to bank A $BA00 with STEPTAB/USEVEC; the driver packs below the engine PMOVE slice at $2600)'),
    ('D_ENABLE',       0x05FE, None, 'forward-coherence bbox cache master switch'),
    ('D_FWD',          0x05FF, None, 'per-frame flag: move was forward-only'),
    ('VXC_STATE',      0x0700, None, 'THE BITMAP PAGE: VCACHE_VALID+VDONE+VXC_VALID+RCACHE_COMPUTED (boot zeroes the whole page)'),
    ('VXC_STATE_LEN',  0x100,  None, 'bytes to zero at boot (the whole bitmap page)'),
    ('VXC_ENABLE',     0x05DB, None, 'translation vertex cache switch'),
    ('RCACHE_STATE',   0xAF00, 0x7268, 'rotation cache header+bitmaps (flat: $F100; carve freed 2026-07-15)'),
    ('RCACHE_STATE_LEN',0x89,  None, 'bytes to zero at boot'),
    ('RCACHE_ENABLE',  0xAF88, 0x72F0, 'rotation-coherence bca cache switch (STATE+$88)'),
    ('CPM_BASE',       0xA600, 0x2900, 'corner-phi memo: 128-slot xor hash, 3 pages ($5500-$57FF flat, ending exactly at the screen). Banked $A600 in bank WALK (two-bank re-cut 2026-08-13). SCAR: an earlier home sat ON ROM_BBOX_C and the memo stores SHREDDED the corner planes (black screen after walking; banked gates compare engine-vs-itself so both sides corrupted identically). Scan the MERGED map before claiming space.'),
    ('CPM_KDXL',       'CPM_BASE+$000', None, 'memo key: corner dx lo'),
    ('CPM_KDXH',       'CPM_BASE+$080', None, '... dx hi; DOUBLES as validity: plane ships $80-filled ($80 = impossible dx hi), so there is no EP plane'),
    ('CPM_KDYL',       'CPM_BASE+$100', None, '... dy lo'),
    ('CPM_KDYH',       'CPM_BASE+$180', None, '... dy hi'),
    ('CPM_PSIL',       'CPM_BASE+$200', None, 'memo value: psi lo'),
    ('CPM_PSIH',       'CPM_BASE+$280', None, '... psi hi (last plane: memo ends at CPM_BASE+$300)'),
    # Player-movement collision map (colmap.py, 2026-08-14). Banked =
    # bank WALK free windows (same bank as the node SoA — one paging
    # context for the whole movement test); flat = the TUBE parasite map
    # (the replaced raster pocket $7600-$82FF + the high-table area).
    # colmap.blobs() asserts every blob against these homes.
    ('COLIDX_BASE',    0xAF8A, 0x7600, 'collision blockmap: 36 x (u16 list addr, u8 count) + the u8 lists (banked: $B4A4 -> $AB00 -> $AF8A 2026-08-15 — off the SSMASK staging page, then off the rcache PSI PLANES $A900-$AEFF; now after RCACHE_STATE, ends $B197)'),
    ('COLSEG_BASE',    0xB8C0, 0x7810, 'collision segments: n x 8 (x1,y1,dx,dy raw s16 LE, center-relative)'),
    ('SS_VZ_BASE',     0x8C00, 0xE750, 'per-subsector prescale(floor+41) (s8)'),
    ('SS_INFO_BASE',   0x8CE0, 0xE830, 'per-subsector mover info: $FF none, else mover idx (b7 = ceil mover)'),
    ('MV_MINPASS',     0xBFC0, 0xE910, 'per-mover min passable door pos (fh + 56, prescaled)'),
    ('COLPORT_BASE',   0x0200, 0x0200, 'P_CheckPosition aggregation ports: 42 x 12 (x1,y1,dx,dy s16 + ob_vz + ot_ps + mover + wall-angle) — the shared page freed by records-to-bank-C; anim_init copies it down from staging (banked: bank B $A900; flat/tube: $8400 CODE slack)'),
    ('COL_N_SOLID',    199,    None,   'collision indices >= this are ports (colmap asserts the count)'),
    ('PM_MOMX',        0x03F8, None,   'player momentum x (s16 8.8 prescaled) — the COLPORT page tail; anim_init\'s 512B copy-down zero-seeds it (bank staging pads with zeros)'),
    ('PM_MOMY',        0x03FA, None,   '... momentum y'),
    ('PM_TICREM',      0x03FC, None,   '35Hz tic accumulator remainder (0..9)'),
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
