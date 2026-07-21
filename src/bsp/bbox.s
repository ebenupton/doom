
; ============================================================================
; br_bbox_visible — node child-subtree visibility gate: is any part of the
; child's bounding box potentially on screen, and does the span list still
; have a gap in the box's column extent?
;
; Mirrors packed_render_bsp's per-child guard (doom_wireframe.py):
;   br = fp_bbox_visible_fixed(node, side, ctx)   # angle-space column extent
;   visible = (br is not None) and clips.has_gap(br[0], br[1])
;
; Inputs:
;   zp_node_ch_l        = node id (u8 — n_nodes <= 256, asserted at pack time)
;   zp_bbox_side        = 0 → right child's box, 1 → left child's box
;   Box table base is the ROM_BBOX_C layout.inc CONSTANT (the zp_rom_bbox
;   pointer pair was retired 2026-07-10): 16 bytes/node = two 8-byte
;   records (right box then left box), each (top, bot, left, right) s16,
;   page-aligned (corner loads build the pointer byte-at-a-time).
;   Per-frame presets (written by view/render setup, constant per frame):
;     bca_pxs/bca_pys   = player x/y sign-extended s16 ($8D/$8E, $9B/$9C)
;     bca_ab            = view angle byte; bca_afn = ab<<4 (hoisted fine angle)
; Output:
;   A = 1 (Z clear) if the box subtends visible screen columns AND
;       span_has_gap([bca_ilo, bca_ihi]) — subtree worth descending;
;   A = 0 (Z set) otherwise. Callers branch on Z (BEQ → skip subtree).
; Clobbers: A, X, Y; $86/$87 (bca_boxp); $C2/$C3 (zp_i_l/zp_i_h);
;   pages bank L2 then bank C in the banked build (caller re-pages after).
;
; Pseudocode:
;   boxp = rom_bbox + node*16 + side*8
;   vis, ilo, ihi = bbox_check_angle(boxp, px, py, ab)   # bca_check_op
;   if not vis: return 0                                 # culled/behind
;   return span_has_gap(ilo, ihi)                        # occlusion query
; ============================================================================
; ============================================================================
; Forward-coherence bbox cache ("D"): REVIVED 2026-07-21 on the rcache
; architecture and moved into src/ang/bca.s (dbox_check) — the frame
; class is a vector (zp_bv_entry), the storage is the rotation cache's
; planes + COMPUTED bitmap (one class live at a time, wiped on entry),
; and the store wraps the pristine per-side tree call at the probe's
; miss (serve-or-compute+store, "cache at birth" for (ilo, ihi)).
; The old wrapper generation (br_bbox_visible_d, br_dcache_frame, the
; $0210-$03F7 code planes, D_MODE/D_SMODE/zp_bv_mode) died with this —
; $0210-$03F7 are FREE again. D_ENABLE/D_FWD (abi.inc) remain the
; driver contract: D_FWD = this frame's move was forward-only.
; ============================================================================
.export D_ENABLE, D_FWD

; ============================================================================
; br_bbox_visible — THE walk-facing bbox entry (2026-07-18, SMC-free;
; vectored 2026-07-20). bca_frame points zp_bv_entry at the frame
; class's entry: bbox_check_angle (standing: rotation-cache probe),
; dbox_check (forward run: D probe), box_classify (pristine).
;   in : zp_node_ch_l/zp_bbox_side = box identity; frame ZP preset
;   out: A/Z = combined verdict (has_gap over the check's extent)
; ============================================================================
br_bbox_visible:
   PAGE BANK_L2                            ; angle tables live in bank L2
::br_bbox_visible_l2:                   ; entry for L2-PROVEN callers (the
                                        ; walk's near-invisible -> far-check
                                        ; arc: bca exits L2 and PLA/stores/
                                        ; IS_FULL_B touch no banked data)
   JMP (zp_bv_entry)                       ; exits return to OUR caller

SEG_CODE                         ; restore for subsequently-included parts
