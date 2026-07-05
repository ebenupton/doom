
; ===================================================================
; umul16x16 — u16 × u16 = u32
; Inputs:  LC_M_A_LO/HI, LC_M_B_LO/HI
; Output:  LC_M_R0..LC_M_R3 (LSB first)
; Clobbers: A, X, Y, zp_mul_b, zp_prod_lo, zp_prod_hi
umul16x16:
.scope
; Always need p1 = a_lo * b_lo.
LDA LC_M_B_LO
STA zp_mul_b
LDA LC_M_A_LO
JSR umul8
LDA zp_prod_lo
STA LC_M_R0
LDA zp_prod_hi
STA LC_M_R1
LDA #0
STA LC_M_R2
STA LC_M_R3

; Fast paths: skip multiplies whose factor is zero.
LDA LC_M_B_HI
BEQ skip_p2

LDA LC_M_B_HI
STA zp_mul_b
LDA LC_M_A_LO
JSR umul8
; p2 = a_lo * b_hi
LDA zp_prod_lo
CLC
ADC LC_M_R1
STA LC_M_R1
LDA zp_prod_hi
ADC LC_M_R2
STA LC_M_R2
LDA #0
ADC LC_M_R3
STA LC_M_R3
skip_p2:

LDA LC_M_A_HI
BEQ skip_p3_p4

LDA LC_M_B_LO
STA zp_mul_b
LDA LC_M_A_HI
JSR umul8
; p3 = a_hi * b_lo
LDA zp_prod_lo
CLC
ADC LC_M_R1
STA LC_M_R1
LDA zp_prod_hi
ADC LC_M_R2
STA LC_M_R2
LDA #0
ADC LC_M_R3
STA LC_M_R3

LDA LC_M_B_HI
BEQ skip_p3_p4
; if b fits u8, p4 = a_hi * 0 = 0
LDA LC_M_B_HI
STA zp_mul_b
LDA LC_M_A_HI
JSR umul8
; p4 = a_hi * b_hi
LDA zp_prod_lo
CLC
ADC LC_M_R2
STA LC_M_R2
LDA zp_prod_hi
ADC LC_M_R3
STA LC_M_R3
skip_p3_p4:
RTS
.endscope

; ===================================================================
; udiv32_16 — u32 ÷ u16 = u16 quotient (low 16 bits, with rounding
; pre-applied by caller)
; Inputs:  LC_M_R0..R3 (dividend, modified); LC_DEN_LO/HI (divisor)
; Output:  LC_QUOT_LO/HI, LC_REM_LO/HI
; Clobbers: A, X, dividend bytes
;
; Fast path (per project_clip_arithmetic_fastpath): byte-level skip of
; leading-zero dividend bytes. Each skipped byte saves 8 iterations
; (~240 cycles). Typical s16 clipper inputs produce a u20-u22 product
; from umul16x16, so R3 is always 0 and we always save ≥8 iterations.
udiv32_16:
.scope
LDA #0
STA LC_QUOT_LO
STA LC_QUOT_HI

; ---- Fast path: quotient fits u16 ----
; True iff top 16 bits of dividend < den. Pre-load rem = R3:R2 and
; run 16 iterations on the low 16 bits (skip the first 16 no-op
; iterations the standard loop would do). For typical s16 clipper
; inputs (product u20-u22, den u12) this is always true.
LDA LC_M_R3
CMP LC_DEN_HI
BCC u16_quot
BNE no_u16_quot
LDA LC_M_R2
CMP LC_DEN_LO
BCS no_u16_quot
u16_quot:
LDA LC_M_R3
STA LC_REM_HI
LDA LC_M_R2
STA LC_REM_LO
LDX #16
u16_loop:
ASL LC_M_R0
ROL LC_M_R1
ROL LC_REM_LO
ROL LC_REM_HI
LDA LC_REM_LO
SEC
SBC LC_DEN_LO
STA LC_TMP_LO
LDA LC_REM_HI
SBC LC_DEN_HI
BCC u16_no_sub
STA LC_REM_HI
LDA LC_TMP_LO
STA LC_REM_LO
SEC
JMP u16_set
u16_no_sub:
CLC
u16_set:
ROL LC_QUOT_LO
ROL LC_QUOT_HI
DEX
BNE u16_loop
RTS

no_u16_quot:
; ---- Slow path: u32 ÷ u16 → up to u17 quotient ----
; (Rare for s16 clipper; kept for correctness.) Use byte-level skip
; + bit-level skip to trim no-op iterations.
LDA #0
STA LC_REM_LO
STA LC_REM_HI
LDX #32
LDA LC_M_R3
BNE bit_skip
LDA LC_M_R2
STA LC_M_R3
LDA LC_M_R1
STA LC_M_R2
LDA LC_M_R0
STA LC_M_R1
ZERO LC_M_R0
LDX #24
LDA LC_M_R3
BNE bit_skip
LDA LC_M_R2
STA LC_M_R3
LDA LC_M_R1
STA LC_M_R2
LDA #0
STA LC_M_R0
STA LC_M_R1
LDX #16
LDA LC_M_R3
BNE bit_skip
LDA LC_M_R2
STA LC_M_R3
LDA #0
STA LC_M_R0
STA LC_M_R1
STA LC_M_R2
LDX #8
LDA LC_M_R3
BNE bit_skip
RTS
bit_skip:
BMI div_loop
bs_loop:
ASL LC_M_R0
ROL LC_M_R1
ROL LC_M_R2
ROL LC_M_R3
DEX
LDA LC_M_R3
BPL bs_loop
div_loop:
ASL LC_M_R0
ROL LC_M_R1
ROL LC_M_R2
ROL LC_M_R3
ROL LC_REM_LO
ROL LC_REM_HI
LDA LC_REM_LO
SEC
SBC LC_DEN_LO
STA LC_TMP_LO
LDA LC_REM_HI
SBC LC_DEN_HI
BCC div_no_sub
STA LC_REM_HI
LDA LC_TMP_LO
STA LC_REM_LO
SEC
JMP div_setbit
div_no_sub:
CLC
div_setbit:
ROL LC_QUOT_LO
ROL LC_QUOT_HI
DEX
BNE div_loop
RTS
.endscope

; ===================================================================
; s16_interp — find target axis at given free-axis value
; The "free" axis is the one whose value we know (the clip target);
; the "target" axis is the one we want to compute. Caller sets:
;   LC_TGT_LO/HI       = target free-axis value (s16)
;   LC_OX1_LO/HI etc.  = anchor 1 (free, target)
;   LC_OX2_LO/HI etc.  = anchor 2 (free, target)
; To clip x at boundary: free=x, target=y, OX*=x, OY*=y.
; To clip y at boundary: free=y, target=x, OX*=y, OY*=x.
; Output: A = clamped u8 result, LC_RES_LO/HI = unclamped s16 result.
; Clobbers: many.
s16_interp:
.scope
; offset = target - x0
LDA LC_TGT_LO
SEC
SBC LC_OX1_LO
STA LC_OFF_LO
LDA LC_TGT_HI
SBC LC_OX1_HI
STA LC_OFF_HI
; den = x1 - x0
LDA LC_OX2_LO
SEC
SBC LC_OX1_LO
STA LC_DEN_LO
LDA LC_OX2_HI
SBC LC_OX1_HI
STA LC_DEN_HI
; If den < 0, negate both offset and den.
LDA LC_DEN_HI
BPL si_den_pos
LDA #0
SEC
SBC LC_OFF_LO
STA LC_OFF_LO
LDA #0
SBC LC_OFF_HI
STA LC_OFF_HI
LDA #0
SEC
SBC LC_DEN_LO
STA LC_DEN_LO
LDA #0
SBC LC_DEN_HI
STA LC_DEN_HI
si_den_pos:
; Trivial: den == 0 (degenerate line) → return y0
LDA LC_DEN_LO
ORA LC_DEN_HI
BNE si_den_nz
JMP si_return_y0
si_den_nz:
; Trivial: offset == 0 (target == x0) → return y0
LDA LC_OFF_LO
ORA LC_OFF_HI
BNE si_off_nz
JMP si_return_y0
si_off_nz:
; Trivial: offset == den (target == x1) → return y1
LDA LC_OFF_LO
CMP LC_DEN_LO
BNE si_off_lt_den
LDA LC_OFF_HI
CMP LC_DEN_HI
BNE si_off_lt_den
JMP si_return_y1
si_off_lt_den:
; dy = y1 - y0 (s16)
LDA LC_OY2_LO
SEC
SBC LC_OY1_LO
STA LC_DY_LO
LDA LC_OY2_HI
SBC LC_OY1_HI
STA LC_DY_HI
; Trivial: dy == 0 (horizontal line) → return y0
LDA LC_DY_LO
ORA LC_DY_HI
BNE si_dy_nz
JMP si_return_y0
si_dy_nz:
; |dy|, sign tracked in LC_DY_NEG
LDA LC_DY_HI
BPL si_dy_pos
LDA #1
STA LC_DY_NEG
LDA #0
SEC
SBC LC_DY_LO
STA LC_DY_LO
LDA #0
SBC LC_DY_HI
STA LC_DY_HI
JMP si_dy_done
si_dy_pos:
LDA #0
STA LC_DY_NEG
si_dy_done:
; Fast path: |offset|, |den|, |dy| all fit u8 → use existing
; umul8 + udiv16_8 (one multiply, one divide-with-skip-zeros).
LDA LC_OFF_HI
ORA LC_DEN_HI
ORA LC_DY_HI
BNE si_general
LDA LC_DY_LO
STA zp_mul_b
LDA LC_OFF_LO
JSR umul8
; round: prod += (den / 2)
LDA LC_DEN_LO
LSR A
CLC
ADC zp_prod_lo
STA zp_div_lo
LDA #0
ADC zp_prod_hi
STA zp_div_hi
LDA LC_DEN_LO
STA zp_div_den
JSR udiv16_8                            ; A = u8 quotient
LDX LC_DY_NEG
BNE si_u8_sub
CLC
ADC LC_OY1_LO
STA LC_RES_LO
LDA LC_OY1_HI
ADC #0
STA LC_RES_HI
JMP si_clamp
si_u8_sub:
STA LC_TMP_LO
LDA LC_OY1_LO
SEC
SBC LC_TMP_LO
STA LC_RES_LO
LDA LC_OY1_HI
SBC #0
STA LC_RES_HI
JMP si_clamp
si_general:
; multiply: |offset| × |dy| → u32 (umul16x16 also has a_hi=0/b_hi=0
; fast paths internally).
LDA LC_OFF_LO
STA LC_M_A_LO
LDA LC_OFF_HI
STA LC_M_A_HI
LDA LC_DY_LO
STA LC_M_B_LO
LDA LC_DY_HI
STA LC_M_B_HI
JSR umul16x16
; round-to-nearest: add (den / 2) before divide
LDA LC_DEN_HI
LSR A
STA LC_TMP_HI
LDA LC_DEN_LO
ROR A
STA LC_TMP_LO
LDA LC_M_R0
CLC
ADC LC_TMP_LO
STA LC_M_R0
LDA LC_M_R1
ADC LC_TMP_HI
STA LC_M_R1
LDA LC_M_R2
ADC #0
STA LC_M_R2
LDA LC_M_R3
ADC #0
STA LC_M_R3
JSR udiv32_16
; result = y0 ± quot
LDA LC_DY_NEG
BNE si_sub
LDA LC_OY1_LO
CLC
ADC LC_QUOT_LO
STA LC_RES_LO
LDA LC_OY1_HI
ADC LC_QUOT_HI
STA LC_RES_HI
JMP si_clamp
si_sub:
LDA LC_OY1_LO
SEC
SBC LC_QUOT_LO
STA LC_RES_LO
LDA LC_OY1_HI
SBC LC_QUOT_HI
STA LC_RES_HI
si_clamp:
LDA LC_RES_HI
BMI si_clamp_zero
BNE si_clamp_max
LDA LC_RES_LO
RTS
si_clamp_zero:
LDA #0
RTS
si_clamp_max:
LDA #$FF
RTS
si_return_y0:
LDA LC_OY1_LO
STA LC_RES_LO
LDA LC_OY1_HI
STA LC_RES_HI
JMP si_clamp
si_return_y1:
LDA LC_OY2_LO
STA LC_RES_LO
LDA LC_OY2_HI
STA LC_RES_HI
JMP si_clamp
.endscope

; ===================================================================
; draw_clipped_line_s16 — clip s16 line to u8 then dispatch to DCL.
; Reads LC_X1_LO..LC_Y2_HI (8 bytes of s16 input).
; Writes u8 to zp_line_xl, zp_line_yl, zp_line_xr, zp_line_yr and
; falls through to draw_clipped_line. If line fully off-screen,
; degenerate, or otherwise rejected, RTS without invoking DCL.
draw_clipped_line_s16:
.scope
; ---- Fast path: all 4 endpoints already in u8 range ----
; HI bytes all zero ⇔ all coords in [0, 255]. Wrapper has already
; written zp_line_xl/yl/xr/yr (= LC_X*_LO via alias), ordered the
; endpoints, and rejected degenerate input. Tail-call DCL directly.
LDA LC_X1_HI
ORA LC_Y1_HI
ORA LC_X2_HI
ORA LC_Y2_HI
BNE main_clip
JMP draw_clipped_line
main_clip:
; ---- Quick reject: both endpoints on the same side of any edge ----
; Both x < 0?  hi byte negative for both means both < 0 (s16).
LDA LC_X1_HI
BPL x1_in_or_big
LDA LC_X2_HI
BPL not_both_xneg
JMP rejected
x1_in_or_big:
; LC_X1_HI ≥ 0. Check if LC_X1_LO/HI > 255 (i.e. HI != 0).
BEQ not_both_xbig                       ; HI = 0 → in [0, 255] (low byte)
; HI > 0 → x1 > 255. Is x2 also > 255?
LDA LC_X2_HI
BMI not_both_xbig
; x2 < 0 → not both > 255
BEQ not_both_xbig                       ; x2 in [0, 255] → not both > 255
; both > 255
JMP rejected
not_both_xneg:
not_both_xbig:
; same for y
LDA LC_Y1_HI
BPL y1_in_or_big
LDA LC_Y2_HI
BPL not_both_yneg
JMP rejected
y1_in_or_big:
BEQ not_both_ybig
LDA LC_Y2_HI
BMI not_both_ybig
BEQ not_both_ybig
JMP rejected
not_both_yneg:
not_both_ybig:

; ---- Skip x-clip path entirely if both x already in u8 ----
; (We got here because at least one HI byte is non-zero; might be y.)
LDA LC_X1_HI
ORA LC_X2_HI
BNE need_xclip
JMP skip_xclip
need_xclip:

; ---- Save originals for x-clip interp (only when needed) ----
LDA LC_X1_LO
STA LC_OX1_LO
LDA LC_X1_HI
STA LC_OX1_HI
LDA LC_Y1_LO
STA LC_OY1_LO
LDA LC_Y1_HI
STA LC_OY1_HI
LDA LC_X2_LO
STA LC_OX2_LO
LDA LC_X2_HI
STA LC_OX2_HI
LDA LC_Y2_LO
STA LC_OY2_LO
LDA LC_Y2_HI
STA LC_OY2_HI

; ---- X clip ----
; If x1 < 0, replace y1 with y at x=0; x1 = 0.
; Else if x1 > 255, replace y1 with y at x=255; x1 = 255.
LDA LC_X1_HI
BPL x1_not_neg
LDA #0
STA LC_TGT_LO
STA LC_TGT_HI
JSR s16_interp
; store the UNCLAMPED crossing Y (LC_RES), not the u8-clamped A: if the
; y-crossing at the x-boundary is itself out of [0,255] the later y-clip
; must still fire. Storing clamped A here zeroed Y_HI, skipped the y-clip,
; and emitted the screen CORNER (wrong slope) — 994,-3291,237 bottom seg.
LDA LC_RES_LO
STA LC_Y1_LO
LDA LC_RES_HI
STA LC_Y1_HI
LDA #0
STA LC_X1_LO
STA LC_X1_HI
JMP x1_done
x1_not_neg:
BEQ x1_done                             ; HI=0 → in u8 range, no clip
LDA #$FF
STA LC_TGT_LO
LDA #0
STA LC_TGT_HI
JSR s16_interp
; store the UNCLAMPED crossing Y (LC_RES), not the u8-clamped A: if the
; y-crossing at the x-boundary is itself out of [0,255] the later y-clip
; must still fire. Storing clamped A here zeroed Y_HI, skipped the y-clip,
; and emitted the screen CORNER (wrong slope) — 994,-3291,237 bottom seg.
LDA LC_RES_LO
STA LC_Y1_LO
LDA LC_RES_HI
STA LC_Y1_HI
LDA #$FF
STA LC_X1_LO
LDA #0
STA LC_X1_HI
x1_done:
; same for x2
LDA LC_X2_HI
BPL x2_not_neg
LDA #0
STA LC_TGT_LO
STA LC_TGT_HI
JSR s16_interp
; store UNCLAMPED crossing Y (see LC_Y1 note above).
LDA LC_RES_LO
STA LC_Y2_LO
LDA LC_RES_HI
STA LC_Y2_HI
LDA #0
STA LC_X2_LO
STA LC_X2_HI
JMP x2_done
x2_not_neg:
BEQ x2_done
LDA #$FF
STA LC_TGT_LO
LDA #0
STA LC_TGT_HI
JSR s16_interp
; store UNCLAMPED crossing Y (see LC_Y1 note above).
LDA LC_RES_LO
STA LC_Y2_LO
LDA LC_RES_HI
STA LC_Y2_HI
LDA #$FF
STA LC_X2_LO
LDA #0
STA LC_X2_HI
x2_done:
skip_xclip:

; ---- Quick reject after x-clip (y might still be out same side) ----
LDA LC_Y1_HI
BPL y1_after_in_or_big
LDA LC_Y2_HI
BPL not_both_yneg2
JMP rejected
y1_after_in_or_big:
BEQ not_both_ybig2
LDA LC_Y2_HI
BMI not_both_ybig2
BEQ not_both_ybig2
JMP rejected
not_both_yneg2:
not_both_ybig2:

; ---- If both y already in u8, skip y-clip ----
LDA LC_Y1_HI
BNE need_yclip
LDA LC_Y2_HI
BNE need_yclip
JMP y_in_range
need_yclip:
; Re-snap originals to post-x-clip values; for y-clip, axes swap:
; OX* now holds the FREE axis (y), OY* the TARGET (x).
LDA LC_Y1_LO
STA LC_OX1_LO
LDA LC_Y1_HI
STA LC_OX1_HI
LDA LC_X1_LO
STA LC_OY1_LO
LDA LC_X1_HI
STA LC_OY1_HI
LDA LC_Y2_LO
STA LC_OX2_LO
LDA LC_Y2_HI
STA LC_OX2_HI
LDA LC_X2_LO
STA LC_OY2_LO
LDA LC_X2_HI
STA LC_OY2_HI

; y1 clip
LDA LC_Y1_HI
BPL y1c_not_neg
LDA #0
STA LC_TGT_LO
STA LC_TGT_HI
JSR s16_interp
STA LC_X1_LO
LDA #0
STA LC_X1_HI
LDA #0
STA LC_Y1_LO
STA LC_Y1_HI
JMP y1c_done
y1c_not_neg:
BEQ y1c_done
LDA #$FF
STA LC_TGT_LO
LDA #0
STA LC_TGT_HI
JSR s16_interp
STA LC_X1_LO
LDA #0
STA LC_X1_HI
LDA #$FF
STA LC_Y1_LO
LDA #0
STA LC_Y1_HI
y1c_done:
; y2 clip
LDA LC_Y2_HI
BPL y2c_not_neg
LDA #0
STA LC_TGT_LO
STA LC_TGT_HI
JSR s16_interp
STA LC_X2_LO
LDA #0
STA LC_X2_HI
LDA #0
STA LC_Y2_LO
STA LC_Y2_HI
JMP y2c_done
y2c_not_neg:
BEQ y2c_done
LDA #$FF
STA LC_TGT_LO
LDA #0
STA LC_TGT_HI
JSR s16_interp
STA LC_X2_LO
LDA #0
STA LC_X2_HI
LDA #$FF
STA LC_Y2_LO
LDA #0
STA LC_Y2_HI
y2c_done:
y_in_range:

; ---- Order/copy/degen handled by wrapper for input; clipping in
; this slow path could shrink the line to a point, so check that
; one case before dispatching. zp_line_* already holds the clipped
; values via the LC_X*_LO aliases.
LDA zp_line_xl
CMP zp_line_xr
BCC dispatch_dcl
BNE rejected_swap_after_clip            ; clipping reordered: bail (rare)
LDA zp_line_yl
CMP zp_line_yr
BEQ rejected
dispatch_dcl:
JMP draw_clipped_line
rejected_swap_after_clip:
; Post-clip x1 > x2 — would require swap; just emit reordered.
LDA zp_line_xl
LDX zp_line_xr
STX zp_line_xl
STA zp_line_xr
LDA zp_line_yl
LDX zp_line_yr
STX zp_line_yl
STA zp_line_yr
JMP draw_clipped_line
rejected:
RTS
.endscope

end_code:
.if ::BANKED
; (ld65 writes this: SAVE "span_clip_bankc.bin", $8000, end_code, $8000)
.else
; (ld65 writes this: SAVE "span_clip.bin", $2000, end_code, $2000)
.endif
