; math_zp.inc — Zero-page API for math routines
;
; Include-guarded: safe to .include from multiple files.

.ifndef MATH_ZP_INC
MATH_ZP_INC = 1

.include "zp_layout.inc"

; ── Multiply / divide interface ─────────────────────────────────────
math_a              = ZP_MATH + 0      ; 1 byte — multiplier input
math_b              = ZP_MATH + 1      ; 1 byte — multiplicand input
math_res_lo         = ZP_MATH + 2      ; result low byte
math_res_hi         = ZP_MATH + 3      ; result high byte

.endif
