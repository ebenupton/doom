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

; ============================================================================
.if ::BANKED
.segment "W_BK"                         ; banked D is capped at $40 by anim_drv
.endif
; rhi==0 projection fast paths (bodies live here — MAIN is full). When the
; reciprocal hi byte is zero (vertex beyond ~1024 world units) the rhi
; product terms are EXACTLY zero: only the rlo term survives.
; ============================================================================
px_rhi0:
; sx = 128 + signext(hi(vx*rlo))    (terms A and C of the 3-mul path = 0)
;   Inputs:  zp_br_t0 = vx (s8), zp_br_rlo. Output: zp_br_resl/h (s16).
;   Reached by JMP from br_project_x_subpx (project.s); RTS returns to
;   ITS caller. One s8×u8 multiply; the sign-extended high byte of the
;   product is the whole non-constant part of sx.
LDA zp_br_t0
STA zp_br_a
LDA zp_br_rlo
STA zp_br_b
JSR br_smul_s8_u8
LDA zp_br_resh
BPL px0_pos
CLC
ADC #128
STA zp_br_resl
LDA #$FF
ADC #0
STA zp_br_resh
RTS
px0_pos:
CLC
ADC #128
STA zp_br_resl
LDA #0
ADC #0
STA zp_br_resh
RTS

py_rhi0:
; sy = 128 - signext(hi(h*rlo))     (term A of the 2-mul path = 0)
;   Inputs:  zp_br_t0 = h (s8), zp_br_rlo. Output: zp_br_resl/h (s16).
;   Reached by JMP from br_project_y_raw (project.s); the 128 constant is
;   the same folded HALF_H + Y_BIAS, so the result stays pre-biased.
LDA zp_br_t0
STA zp_br_a
LDA zp_br_rlo
STA zp_br_b
JSR br_smul_s8_u8
LDX #0
LDA zp_br_resh
BPL py0_ext
LDX #$FF
py0_ext:
STA zp_br_t2
STX zp_br_t3
LDA #128
SEC
SBC zp_br_t2
STA zp_br_resl
LDA #0
SBC zp_br_t3
STA zp_br_resh
RTS
.if ::BANKED
.segment "D_BK"                         ; back for the region-end marker
.endif

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
VWHC_VALID = $A700
VWHC_RHI = $A800
VWHC_RLO = $A900
VWHC_H = $AA00
VWHC_LO = $AB00
VWHC_HI = $AC00
.segment "W_BK"
.else
VWHC_VALID = $D4C0
VWHC_RHI = $D5C0
VWHC_RLO = $D6C0
VWHC_H = $D7C0
VWHC_LO = $D8C0
VWHC_HI = $D9C0
.segment "W"
.endif
