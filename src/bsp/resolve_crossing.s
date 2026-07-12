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
; (VWHC pages moved $A800-$ACFF -> $B500-$B9FF in the 2026-07-10 reshuffle:
; verts now occupy $A200-$A95x. VALID retired earlier — RLO doubles as valid.)
VWHC_RHI = $B500
VWHC_RLO = $B600
VWHC_H = $B700
VWHC_LO = $B800
VWHC_HI = $B900
.segment "W_BK"
.else
; PAGE-ALIGNED 2026-07-12 (were $D5C0-$D9C0: the $C0 offset made ~75% of
; abs,X probes pay the page-cross +1 — flat build only; banked was
; already aligned, so the harness metric overcharged the y-cache).
; BSS window $D4C0-$DABF: aligned tables span $D500-$D9FF, $D4C0-$D4FF
; and $DA00-$DABF free.
VWHC_RHI = $D500
VWHC_RLO = $D600
VWHC_H = $D700
VWHC_LO = $D800
VWHC_HI = $D900
.segment "W"
.endif
