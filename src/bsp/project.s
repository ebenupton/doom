
; ============================================================================
; br_project_x_subpx — project view-space X to screen X with sub-pixel.
;
;   Inputs (zp):
;     zp_br_t0 = vx (s8, truncated view-space x)
;     zp_br_t1 = vx_frac (u8, fractional part)
;     zp_br_rhi, zp_br_rlo = reciprocal (u8 each)
;
;   Output:
;     zp_br_resl/h = sx (s16 screen x)
;
;   Python:
;     sx = HALF_W + m8(vx, recip_hi) + (m8(vx, recip_lo) >> 8)
;                + (m8(vx_frac, recip_hi) >> 8)
;
;   Three 8x8 multiplies: signed s8×u8 (×2) and unsigned u8×u8 (×1).
; ============================================================================
br_project_x_subpx:
.scope
; rhi==0 (vertex beyond ~1024 world units — recip < 1.0): terms A
; (vx*rhi) and C (vx_frac*rhi >> 8) are EXACTLY zero, so only term B
; survives: sx = 128 + signext(hi(vx*rlo)). 1 multiply instead of 3.
LDA zp_br_rhi
BNE px_full
JMP px_rhi0                             ; handler lives in the D region
px_full:
; sum := HALF_W (128) as s16
LDA #128
STA zp_br_vxlo
; reuse vxlo/hi as accumulator for sx
LDA #0
STA zp_br_vxhi

; --- Add A = signed(vx) × u8(recip_hi) ---
LDA zp_br_t0
STA zp_br_a
LDA zp_br_rhi
STA zp_br_b
JSR br_smul_s8_u8
LDA zp_br_vxlo
CLC
ADC zp_br_resl
STA zp_br_vxlo
LDA zp_br_vxhi
ADC zp_br_resh
STA zp_br_vxhi

; --- Add B = (signed(vx) × u8(recip_lo)) >> 8 ---
; Compute s16 product, take HI byte as s8, sign-extend, add to sum.
LDA zp_br_t0
STA zp_br_a
LDA zp_br_rlo
STA zp_br_b
JSR br_smul_s8_u8
LDA zp_br_resh
STA zp_br_t2
; s8 hi byte of product = "B" value
; Sign-extend t2 into a 16-bit add.
LDA zp_br_t2
BPL b_pos
LDA #$FF
STA zp_br_t3
; sign-extension byte
JMP b_have_ext
b_pos:
LDA #0
STA zp_br_t3
b_have_ext:
LDA zp_br_vxlo
CLC
ADC zp_br_t2
STA zp_br_vxlo
LDA zp_br_vxhi
ADC zp_br_t3
STA zp_br_vxhi

; --- Add C = (u8(vx_frac) × u8(recip_hi)) >> 8 ---
; (exactly zero when the fractional view-x is zero — skip the multiply)
LDA zp_br_t1
BEQ px_c_done
LDA zp_br_rhi
STA zp_mul_b
LDA zp_br_t1
JSR SC_UMUL8
LDA zp_prod_hi
CLC
ADC zp_br_vxlo
STA zp_br_vxlo
LDA #0
ADC zp_br_vxhi
STA zp_br_vxhi
px_c_done:

; Move sum into resl/h (the standard output slot).
LDA zp_br_vxlo
STA zp_br_resl
LDA zp_br_vxhi
STA zp_br_resh
RTS
.endscope

; ============================================================================
; br_project_y — project height delta to screen Y.
;
;   Inputs (zp):
;     zp_br_t0 = height_delta (s8)
;     zp_br_rhi, zp_br_rlo = reciprocal
;
;   Output:
;     zp_br_resl/h = sy (s16)
;
;   Python:
;     sy = HALF_H - (m8(h, recip_hi) + (m8(h, recip_lo) >> 8))
; ============================================================================
br_project_y_raw:
.scope
; rhi==0: term A (h*rhi) is exactly zero -> sy = 128 - signext(hi(h*rlo)).
LDA zp_br_rhi
BNE py_full
JMP py_rhi0                             ; handler lives in the D region
py_full:
; sum := HALF_H + Y_BIAS (80 + 48) as s16 — the bias every consumer
; previously added (copy_seg_to_vx, ap2_solid_proj) is folded into
; the projection constant. Same final values, no per-store adds.
LDA #128
STA zp_br_vxlo
LDA #0
STA zp_br_vxhi

; --- Subtract A = signed(h) × u8(recip_hi) ---
LDA zp_br_t0
STA zp_br_a
LDA zp_br_rhi
STA zp_br_b
JSR br_smul_s8_u8
LDA zp_br_vxlo
SEC
SBC zp_br_resl
STA zp_br_vxlo
LDA zp_br_vxhi
SBC zp_br_resh
STA zp_br_vxhi

; --- Subtract B = (signed(h) × u8(recip_lo)) >> 8 ---
LDA zp_br_t0
STA zp_br_a
LDA zp_br_rlo
STA zp_br_b
JSR br_smul_s8_u8
LDA zp_br_resh
STA zp_br_t2
LDA zp_br_t2
BPL py_b_pos
LDA #$FF
STA zp_br_t3
JMP py_b_have_ext
py_b_pos:
LDA #0
STA zp_br_t3
py_b_have_ext:
LDA zp_br_vxlo
SEC
SBC zp_br_t2
STA zp_br_vxlo
LDA zp_br_vxhi
SBC zp_br_t3
STA zp_br_vxhi

LDA zp_br_vxlo
STA zp_br_resl
LDA zp_br_vxhi
STA zp_br_resh
RTS
.endscope

; ============================================================================
; ROM/RAM base addresses (Python wrapper writes these into ZP at frame start)
; ============================================================================
zp_rom_verts_lo = $0BEC
zp_rom_verts_hi = $0BED
zp_rom_ss_lo = $0BF0
zp_rom_ss_hi = $0BF1
zp_rom_seg_hdr_lo = $0BF2
zp_rom_seg_hdr_hi = $0BF3
zp_rom_vwh_lo = $0BF4
zp_rom_vwh_hi = $0BF5
zp_rom_detail_lo = $0BF6
zp_rom_detail_hi = $0BF7

; BSP traversal state
BSP_STACK = $0A00                       ; 32 entries × 2 bytes = 64-byte stack at $0A00-0A3F

; Side-test result holder

; --- Node-read scratch ---
