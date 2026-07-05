bsp_w_start:

br_project_y:
.scope
PAGE BANK_L2                            ; recip + VWHC cache live in bank L2
; probe: idx = (rlo + h + rhi) & 255
LDA zp_br_rlo
CLC
ADC zp_br_t0
ADC zp_br_rhi
TAX
LDA VWHC_VALID,X
BEQ pyc_miss
LDA VWHC_RHI,X
CMP zp_br_rhi
BNE pyc_miss
LDA VWHC_RLO,X
CMP zp_br_rlo
BNE pyc_miss
LDA VWHC_H,X
CMP zp_br_t0
BNE pyc_miss
LDA VWHC_LO,X
STA zp_br_resl
LDA VWHC_HI,X
STA zp_br_resh
RTS
pyc_miss:
STX zp_pyc_idx
JSR br_project_y_raw
LDX zp_pyc_idx
LDA #1
STA VWHC_VALID,X
LDA zp_br_rhi
STA VWHC_RHI,X
LDA zp_br_rlo
STA VWHC_RLO,X
LDA zp_br_t0
STA VWHC_H,X
LDA zp_br_resl
STA VWHC_LO,X
LDA zp_br_resh
STA VWHC_HI,X
RTS
.endscope

; vwhc_clear — invalidate the projection + rotation-product caches (per frame).
vwhc_clear:
.scope
LDA #0
LDX #0
vc_loop:
STA VWHC_VALID,X
INX
BNE vc_loop
; (RPC rotation-product cache removed: $DC00 reclaimed for angle TA_LO.)
RTS
.endscope

bsp_w_end:
.assert bsp_w_end <= $DC00, error       ; stay below angle TA_LO (was RPC_VALID, removed)
.if ::BANKED
; (ld65 writes this: SAVE "bsp_render_w_bk.bin", $3900, bsp_w_end, $3900)
.else
; (ld65 writes this: SAVE "bsp_render_w.bin", $DAC0, bsp_w_end, $DAC0)
.endif

; ============================================================================
; OVERFLOW REGION — bsp_render.bin is bound to $4800-$57FF (4096 bytes max,
; framebuffer starts at $5800). Helpers that don't fit live here at $1C00 and
; are loaded as a separate binary by span_clip_6502.py (bsp_render_lo.bin).
; ============================================================================
.segment "LO"
