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
    ('MAIN_BASE',      0x1A00, None, 'engine CODE region head — $2500 -> $1A00 2026-08-26 (the LOW-RAM CONSOLIDATION: driver $0F00 | PMOVE $1340 | CODE $1A00 = ONE contiguous engine area to $57FF, freeing ~2.9K below the framebuffer). History: engine CODE region head (cfg-anchored; MAIN first). $2A00 -> $2600 2026-08-19: the -$400 window slide that took the pm_frame code out of bank B — strip $1600, window $1A00-$25FF, CODE $2600 with PMB1-4 appended identically in both builds. $2600 -> $2500 2026-08-23: PMOVE+PMH are 1,728 B and stopped at $24FF, leaving the PMOVE region a dead last page; CODE takes it (+256 B) and the window shrinks to $1A00-$24FF. Both cfgs move together — bottom-22K identity.'),
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
    ('DRV_ORG',        0x0F00, None, '$1A00 -> $0F00 2026-08-26 (low-RAM consolidation; the driver heads the ONE engine code area). walk/anim driver entry (!BOOT CALLs this). $1E00 -> $1A00 2026-08-19 (the -$400 window slide, bank-B code eviction): the exception window is $1A00-$25FF — banked walk_drv+PMOVE, flat VXC_YLO/YHI + CPM keys + records + PM_SCRATCH + PMH.'),
    ('DRV_VARS',       0x0B10, None, 'UNIFIED both builds 2026-08-26: the 16-byte hole in the WORK segment between PM_FXW and the scalars ($0B10-$0B1F) — one address, no flat/tube fork (the $1180 flat home died with the map). walk driver variable block (layout below). Banked base $1B80 -> $1BF0 2026-08-24: the block sat in the MIDDLE of walk_drv\'s ORG\'d span, capping the code at 384 B, and the OSBYTE font probe did not fit. The span is code | glue (DRV_GLUE) | vars | input+flip (DRV_CLR), so the vars now occupy the 16 free bytes below DRV_CLR and the code\'s real limit is DRV_GLUE -- which is what walk_drv now asserts, at both ends. FLAT is $1180 because $1B00-$1BFF there is the SENIOR page of VXC_YLO: the seg pipeline cached vertices 384..396 straight over the old block -- vertex 387 landed on DV_PXL and the player X jumped mid-turn. Banked never saw it (VXC lives in bank A), so only the TUBE, which runs the flat engine with a driver, was corrupted. $1180 verified clear by poisoning $1100-$11FF and running render+anim_tick+pm_frame.'),
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
    ('DV_SPACE_PREV',  'DRV_VARS+11', None, 'SPACE edge-detect state (walk_drv). Was a PRIVATE walk_drv equate until 2026-08-24, when DV_HUD_FONT was added at the same offset and silently ate it AND mv_dir -- SPACE stopped retriggering and the move direction was corrupted. The whole block is described HERE now; private copies of these offsets are what hud.s already warns about.'),
    ('DV_MV_DIR',      'DRV_VARS+12', None, 'effective move direction this attempt (walk_drv). Also formerly private -- see DV_SPACE_PREV.'),
    ('HUD_FONT_B',     0xC000, None, 'MOS font base on OS 0.x/1.x (Model B/B+). Picked by OSBYTE 129 at driver entry -- the glyphs are NOT at a fixed address.'),
    ('HUD_FONT_MASTER',0xF900, None, 'MOS font base on MOS 3.20 (Master 128). Verified against the ROM image: the 96 glyphs sit at $F900-$FBFF, ending exactly at the $FC00 I/O boundary. ASSUMED for any OS version 3..$7F, which includes MOS 5 (Master Compact) -- unverified there.'),
    ('DV_HUD_FONT',    'DRV_VARS+13', None, 'MOS font base found by hud_find (TWO bytes, +13/+14; 0 = not searched, $FFxx = searched and absent). The glyphs are NOT at a fixed address: OS 1.2 $C000, MOS 3.20 $F900.'),
    ('DV_FIELDS',      'DRV_VARS+15', None, 'PAL fields consumed by the last frame, for the debug HUD (F=). Written by walk_drv\'s mv_frame from the field-clock search result -- the same count it hands pm_frame, so the readout is the number the movement actually used, not a second estimate of it. The tube build carries the equivalent in its HUD packet.'),
    ('DRV_GLUE',       0x10A0, None, 'anim/HUD glue pocket'),
    ('DRV_CLR',        0x1100, None, 'input block + flip scheduler; the unrolled framebuffer clears moved to BANK C 2026-08-16, and the whole driver slid $2200 -> $2100 with DRV_ORG 2026-08-17 (2026-08-14: the sincos overlay moved to bank A $BA00 with STEPTAB/USEVEC; the driver packs below the engine PMOVE region)'),
    ('PM_FXW',         0x0B00, None, 'world-fraction bytes of the CANDIDATE/committed position, x at +0 / y at +2 (4-byte block $096B-$096E, freed by the u8 BSP child staging retirement). Staged by pmf_cand = (candidate 8.8-prescaled byte0) << 3; consumed by the EXACT node point-on-side (axis ties + node_band) and nowhere else. Harnesses that poke the $90-$93 raws directly MUST poke these too (zero for integer positions).'),
    ('D_ENABLE',       0x0B7E, None, 'forward-coherence bbox cache master switch'),
    ('D_FWD',          0x0B7F, None, 'per-frame flag: move was forward-only'),
    ('VXC_STATE',      0x0700, None, 'THE BITMAP PAGE: VCACHE_VALID+VDONE+VXC_VALID+RCACHE_COMPUTED (boot zeroes the whole page)'),
    ('VXC_STATE_LEN',  0x100,  None, 'bytes to zero at boot (the whole bitmap page)'),
    ('VXC_ENABLE',     0x0B5D, None, 'translation vertex cache switch (scalars block $05xx -> $1Dxx sqr swap -> $19xx window slide -> $19DB->$19DD 2026-08-22 to clear the span pool 15th/16th planes; vxc_prev_ab follows it)'),
    ('RCACHE_STATE',   0xAF00, 0x7268, 'rotation cache header+bitmaps (flat: $F100; carve freed 2026-07-15)'),
    ('RCACHE_STATE_LEN',0x89,  None, 'bytes to zero at boot'),
    ('RCACHE_ENABLE',  0xAF88, 0x72F0, 'rotation-coherence bca cache switch (STATE+$88)'),
    ('CPM_BASE',       0xA600, 0x1800, 'corner-phi memo: 128-slot xor hash, 6 planes. This is the KEY head — 4 key planes, $200 long (the value planes hang off CPM_PSI_BASE, split out flat-side 2026-08-17). Banked $A600 in bank WALK (two-bank re-cut 2026-08-13). SCAR: an earlier home sat ON ROM_BBOX_C and the memo stores SHREDDED the corner planes (black screen after walking; banked gates compare engine-vs-itself so both sides corrupted identically). Scan the MERGED map before claiming space.'),
    ('CPM_KDXL',       'CPM_BASE+$000', None, 'memo key: corner dx lo'),
    ('CPM_KDXH',       'CPM_BASE+$080', None, '... dx hi; DOUBLES as validity: plane ships $80-filled ($80 = impossible dx hi), so there is no EP plane'),
    # The dy key planes split out flat-side 2026-08-17 for the same reason
    # the psi planes did: CODE's head moved down again, to $2A00, and flat
    # has to clear the page. They land on the page RECIP_S vacated when it
    # left main for bank A. Banked keeps the memo contiguous.
    ('CPM_KDY_BASE',   'CPM_BASE+$100', 0x1700, 'dy key planes head (banked: inline; flat: the page RECIP_S left)'),
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
    ('CYMIN_BASE',     0xB200, 0x7F10, 'per-colseg min y cell ((ymin+1584)>>7 clamped u8), indexed by the raw collision index — the column scan prescreen (2026-08-29). Banked: the COLIDX-to-ANIM gap ($B198-$B2FF). Flat: the hole PMOVE vacated 2026-08-23 (COLSEG ends $7F0F, RC_P2L_0 owns $8100). NOT $D700/$D800: CPM_PSI planes + RECIP_S live there — that stomp garbled the tube copro 2026-08-29'),
    ('CYMAX_BASE',     0xB600, 0x8000, 'per-colseg max y cell — see CYMIN_BASE. Banked: the free page below the DIR planes (SS_CNT owns $B500). Flat: 199 entries end $80C6, clear of RC_P2L_0 $8100'),
    ('CYPORT_BASE',    0xB6C7, 0x80C7, 'per-PORT packed y-cell nibbles ((ymaxcell<<4)|ymincell, 256-unit cells), indexed by idx-COL_N_SOLID — the port arm of the scan prescreen (2026-08-29). Rides the CYMAX page tail both builds (banked $B600 page is free below the DIR planes; flat CYMAX ends $80C6, RC_P2L_0 walls $8100)'),
    ('SS_VZ_BASE',     0x8D00, 0xE750, 'per-subsector prescale(floor+41) (s8). Banked $8D00 since 2026-08-19: the fifth of the five adjacent SS planes in bank B ($8900 PC, $8A00 SI, $8B00 FH, $8C00 CH, $8D00 VZ)'),
    # (SS_INFO_BASE retired 2026-08-19: the mover info rides SS_SI bits 5-7 —
    #  idx 0-5, 7 = none; the b7 ceiling flag it carried is per-mover constant
    #  and lives in MV_CEIL)
    ('MV_SS_ID',       0xBFC6, 0xE980, 'mover-subsector probe list: <=8 ids, $FF-padded (pmove scans it twice per move — the 2026-08-19 claw-back that kept SS_PLO plain)'),
    ('MV_SS_INFO',     0xBFCE, 0xE988, 'parallel info bytes, classic SS_INFO format (mover idx, b7 = ceiling)'),
    ('MV_MINPASS',     0xBFC0, 0xE910, 'per-mover min passable door pos (fh + 56, prescaled)'),
    ('COLPORT_BASE',   0x0D00, 0x0D00, 'P_CheckPosition aggregation ports: 42 x 12 (x1,y1,dx,dy s16 + ob_vz + ot_ps + mover + wall-angle). Strip head since the 2026-08-19 window slide: LOW / the tube CODE file load from LOW_BASE = here, so the ports SHIP DIRECTLY.'),
    ('LOW_BASE',       'COLPORT_BASE+0', None, 'first shipped byte of the LOW disc image / tube CODE file / bare-boot copy (the strip head)'),
    ('SPAN_POOL',      0x0800, None, 'clipper span pool block head (13 x $20 fields; arith.s POOL derives from this)'),
    ('PMOVE_BASE',     0x1340, None, 'PMOVE region head (banked cfg anchor; build_anim_ssd asserts driver_end <= this)'),
    ('COL_N_SOLID',    199,    None,   'collision indices >= this are ports (colmap asserts the count)'),
    ('PM_TURNREM',     0x0B04, None,   'sub-step rotation fraction, Q8 — carries the frame-rate-compensated turn across frames. Moved into the WORK segment 2026-08-26; the PM_MOMX/Y tombstone slots (and the pm_fuzz stay-zero assert) DIED with the old map.'),
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
    env = {}        # banked values
    envf = {}       # flat values -- so a symbol DERIVED from a per-build
                    # base (DV_PXL = DRV_VARS+3) gets its own _FLAT, instead
                    # of silently inheriting the banked base. That gap put
                    # the tube driver at $1B83 and the flat engine at $1183
                    # after DRV_VARS forked.
    for name, bank, flat, comment in ABI:
        v = bank
        if isinstance(v, str):
            v = eval(v.replace('$', '0x'), {}, env)
        env[name] = v
        vf = flat if flat is not None else bank
        if isinstance(vf, str):
            vf = eval(vf.replace('$', '0x'), {}, envf)
        envf[name] = vf
        f.write(f'{name} = 0x{v:04X}  # {comment}\n' if v > 9
                else f'{name} = {v}  # {comment}\n')
        if vf != v:
            f.write(f'{name}_FLAT = 0x{vf:04X}\n')

# --- DRV_VARS block occupancy check -------------------------------------
# walk_drv ORGs its glue at DRV_VARS+$10, so the block is +0..+15, and two
# fields must never share an offset. This is the check that would have
# caught DV_HUD_FONT landing on space_prev/mv_dir.
_DV_SIZES = {'DV_HUD_FONT': 2}          # everything else is one byte
_occ = {}
for name, bank, flat, comment in ABI:
    if not (isinstance(bank, str) and bank.startswith('DRV_VARS+')):
        continue
    off = int(bank.split('+')[1])
    for i in range(_DV_SIZES.get(name, 1)):
        if off + i in _occ:
            raise SystemExit(f'ABI ERROR: {name} at DRV_VARS+{off + i} '
                             f'collides with {_occ[off + i]}')
        if off + i >= 0x10:
            raise SystemExit(f'ABI ERROR: {name} at DRV_VARS+{off + i} '
                             f'runs into the glue at DRV_VARS+$10')
        _occ[off + i] = name
print(f'DRV_VARS block: {len(_occ)}/16 bytes used, no collisions')

print('wrote src/abi.inc, abi_beeb.inc, abi.py')
