
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
;   zp_node_chlo        = node id (u8 — n_nodes <= 256, asserted at pack time)
;   zp_bbox_side        = 0 → right child's box, 1 → left child's box
;   zp_rom_bbox_lo/hi   = box-table base (page-aligned, asserted by loaders):
;                         16 bytes/node = two 8-byte records (right box then
;                         left box), each (top, bot, left, right) as 4 × s16.
;   Per-frame presets (written by view/render setup, constant per frame):
;     bca_pxs/bca_pys   = player x/y sign-extended s16 ($8D/$8E, $9B/$9C)
;     bca_ab            = view angle byte; bca_afn = ab<<4 (hoisted fine angle)
; Output:
;   A = 1 (Z clear) if the box subtends visible screen columns AND
;       span_has_gap([bca_ilo, bca_ihi]) — subtree worth descending;
;   A = 0 (Z set) otherwise. Callers branch on Z (BEQ → skip subtree).
; Clobbers: A, X, Y; $86/$87 (bca_boxp); $C2/$C3 (zp_ilo/zp_ihi);
;   pages bank L2 then bank C in the banked build (caller re-pages after).
;
; Pseudocode:
;   boxp = rom_bbox + node*16 + side*8
;   vis, ilo, ihi = bbox_check_angle(boxp, px, py, ab)   # BCA_CHECK
;   if not vis: return 0                                 # culled/behind
;   return span_has_gap(ilo, ihi)                        # occlusion query
; ============================================================================
br_bbox_visible:
.scope
PAGE BANK_L2                            ; bbox + angle tables (TA/VATOX) live in bank L2
; --- bca_boxp = ROM_BBOX + node_id*16 + side*8, exploiting the base's
; page alignment (asserted by the loaders): the record never straddles a
; page, so lo = (node & 15)<<4 | side<<3 and hi = base_hi + (node >> 4)
; — byte-at-a-time, no 16-bit shift chain. Node ids are u8. ---
LDA zp_node_chlo
LSR A
LSR A
LSR A
LSR A
CLC
ADC zp_rom_bbox_hi
STA $87
LDA zp_node_chlo
ASL A
ASL A
ASL A
ASL A
LDX zp_bbox_side
BEQ bv_side_done
ORA #8
bv_side_done:
STA $86

; --- Angle-space visibility (px=$01, py=$03, ab=$FA2F preset per frame) ---
; BCA_CHECK = bbox_check_angle (angle module, DOOM R_CheckBBox in the
; unsigned-BAM phi convention; angle_bbox.py mirror): picks the 2
; silhouette corners for the player's zone, converts their angles to a
; conservative column extent, clips against the view cone. Writes
; bca_vis (1=some columns visible, 0=cull) and bca_ilo/bca_ihi (u8
; column extent, ±1 conservative).
JSR BCA_CHECK
LDA bca_vis
BNE bv_anglevis
LDA #0
RTS
; box wholly outside view cone → invisible (A=0, Z set)
bv_anglevis:
; Visible columns exist — ask the clipper whether any of them still
; have an open span. Tail-call: SC_HAS_GAP's A (1=gap, 0=fully
; occluded) and flags are our return value.
LDA bca_ilo
STA $C2
; zp_ilo
LDA bca_ihi
STA $C3
; zp_ihi
PAGE BANK_C
JMP SC_HAS_GAP

.endscope
