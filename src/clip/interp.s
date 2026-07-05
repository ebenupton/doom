; (pad removed after udiv16_8)

; (seg_interp_store + smul8 removed — replaced by u8 interp_store with Y_BIAS)

; ======================================================================
; INTERP_STORE: interpolate Y at column X (u8 result)
;
; Used for both old span boundaries AND new seg boundaries (with Y_BIAS,
; all Y values are u8).  Direction-split: always unsigned multiply |dy|.
; Caller pre-computes den = xhi - xlo once per span and reuses it
; for all 4 boundary interps (tl, tr, bl, br).
;
; Input: A = x (eval point), zp_i_x0, zp_i_y0, zp_i_y1, zp_div_den
; Output: A = interpolated Y (u8)
; ======================================================================

interp_store:
.scope
; offset = x - x0 (A holds x on entry)
SEC
SBC zp_i_x0
BEQ is_y0
; |||
CMP zp_div_den
BEQ is_y1
; ||
STA zp_mul_b                            ; |
; Direction check: compare y1 vs y0. Always unsigned multiply |dy|.
LDA zp_i_y1
CMP zp_i_y0
BEQ is_y0
BCC descending
; ||||
; ASCENDING (y1 > y0): dy = y1 - y0 (unsigned)
SEC
SBC zp_i_y0
; |
JSR umul_round_div                      ; |
CLC
ADC zp_i_y0
RTS
; | y0 + quot
descending:
; DESCENDING (y1 < y0): |dy| = y0 - y1 (unsigned)
LDA zp_i_y0
SEC
SBC zp_i_y1
; |
JSR umul_round_div                      ; |
EOR #$FF
SEC
ADC zp_i_y0
RTS
; | y0 - quot
is_y0:
LDA zp_i_y0
RTS
; ||
is_y1:
LDA zp_i_y1
RTS
; ||
.endscope

; Shared helper: umul8 + round-to-nearest + udiv16_8 (tail-call).
; Input: A = |dy| (u8), zp_mul_b = offset (u8), zp_div_den set.
; Output: A = quotient (u8). Product always positive.
umul_round_div:
.scope
JSR umul8
LDA zp_div_den
LSR A
CLC
ADC zp_prod_lo
STA zp_prod_lo
LDA zp_prod_hi
ADC #0
STA zp_prod_hi
JMP udiv16_8                            ; tail-call
.endscope
