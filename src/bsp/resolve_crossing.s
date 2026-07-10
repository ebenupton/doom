bsp_d_start:

; bsp_resolve_child — ch := children[zp_bbox_side] of node ch.
;   ptr = rom_nodes + id*16; child_r at +8, child_l at +10.
;   (The line above describes the ORIGINAL AoS node reader; children now
;   come from the SoA pages NODE_CRLO/CRHI/CLLO/CLHI — one 256-byte page
;   per byte, indexed by node id — see wad_packed.build_packed.)
;   Inputs:  zp_node_chlo = node id (u8), zp_bbox_side = 0 (right child)
;            or nonzero (left child).
;   Output:  zp_node_chlo:chhi = child id (bit 15 set = subsector leaf).
;   Used by the walk after a bbox-visibility verdict picks which child
;   of a deferred node to descend.
bsp_resolve_child:
.scope
   PAGE BANK_L0                            ; node SoA pages live in bank L0
   LDX zp_node_chlo
   LDA zp_bbox_side
   BNE rc_left
   LDA NODE_CRLO,X
   STA zp_node_chlo
   LDA NODE_CRHI,X
   STA zp_node_chhi
   RTS
rc_left:
   LDA NODE_CLLO,X
   STA zp_node_chlo
   LDA NODE_CLHI,X
   STA zp_node_chhi
   RTS
.endscope


.if ::BANKED
.segment "D_BK"                         ; back for the region-end marker
.endif

; rns24 half constants, indexed S-1 (S in 1..10):
;   half = 2^(S-1) = rns_half_lo + (rns_half_mid << 8)
rns_half_lo:
   .byte $01, $02, $04, $08, $10, $20, $40, $80, $00, $00
rns_half_mid:
   .byte $00, $00, $00, $00, $00, $00, $00, $00, $01, $02


bsp_d_end:
.if ::BANKED
; (ld65 writes this: SAVE "bsp_render_d_bk.bin", $3BC0, bsp_d_end, $3BC0)
.else
.assert bsp_d_end <= $09FB, error       ; $09FB-$09FD hold DEFQ_TAIL/OVF + corner idx
; (ld65 writes this: SAVE "bsp_render_d.bin", $0978, bsp_d_end, $0978)
.endif





; ============================================================================
; W REGION ($DAC0-$DFFF) — Y-projection cache. Free RAM between the
; harness-loaded bbox table (ends $D4BF) and the recip table ($E000);
; the cache arrays occupy $D4C0-$DABF. Loaded as bsp_render_w.bin.
;
; br_project_y is now a caching front for br_project_y_raw: the key is
; the COMPLETE input set (rhi, rlo, h), so a hit returns the previously
; computed value — bit-identical by construction. 58-64%% of projections
; repeat within a frame (measured); a raw projection costs ~315 cycles
; end-to-end, a hit ~45.
; ============================================================================
; VWHC y-projection cache: flat @ $D4C0; banked -> bank L2 ($A600). br_project_y
; (this code) -> banked low RAM ($3900, clipper-vacated space) since $DAC0 is in
; MOS-ROM space on a real Model B.
.if ::BANKED
; ($A700 page freed 2026-07-10: VWHC_VALID retired — RLO doubles as valid)
VWHC_RHI = $A800
VWHC_RLO = $A900
VWHC_H = $AA00
VWHC_LO = $AB00
VWHC_HI = $AC00
.segment "W_BK"
.else
; ($D4C0 page freed 2026-07-10: VWHC_VALID retired — RLO doubles as valid)
VWHC_RHI = $D5C0
VWHC_RLO = $D6C0
VWHC_H = $D7C0
VWHC_LO = $D8C0
VWHC_HI = $D9C0
.segment "W"
.endif
