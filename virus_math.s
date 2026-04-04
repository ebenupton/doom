; math.s — Fixed-point multiply and division routines for 65C02
;
; Designed as an .include module: no .segment directives, no entry point.
; Include once from your main source file after tables.inc (which provides
; the lookup tables referenced here).
;
; =====================================================================
; Overview
; =====================================================================
;
; This module provides:
;
;   umul8x8          Unsigned  8x8 -> 16-bit multiply (quarter-square)
;   smul8x8          Signed    8x8 -> 16-bit multiply (quarter-square)
;   recip8           Unsigned  floor(32768/z) for 16-bit z, 8-bit result
;
; =====================================================================
; Quarter-square multiplication
; =====================================================================
;
; Both umul8x8 and smul8x8 use the identity:
;
;   a * b = floor((a+b)^2 / 4) - floor((a-b)^2 / 4)
;
; This converts a multiply into two table lookups (sqr[sum], sqr[|diff|])
; and a 16-bit subtract.  Two sets of tables handle sum overflow:
;
;   sqr_lo/sqr_hi     — floor(n^2/4) for n = 0..255
;   sqr2_lo/sqr2_hi   — floor(n^2/4) for n = 256..511
;
; smul8x8 applies a signed correction afterwards:
;   if a < 0:  result_hi -= b
;   if b < 0:  result_hi -= a
;
; =====================================================================
; Table dependencies (from tables.inc)
; =====================================================================
;
;   sqr_lo, sqr_hi         — floor(n^2/4) lo/hi for n=0..255
;   sqr2_lo, sqr2_hi       — floor(n^2/4) lo/hi for n=256..511
;
; =====================================================================
; Register and ZP conventions
; =====================================================================
;
;   Zero page:  math_b (input), math_res_lo/hi (outputs)
;               — defined in math_zp.inc.
;
;   First arg:  passed in A (not math_a).
;   High byte:  returned in A (= math_res_hi) for all multiply functions.
;
;   Y register: preserved by smul8x8 and umul8x8 (PHY/PLY around body).
;               NOT preserved by recip8.
;
; =====================================================================

.include "math_zp.inc"

; =====================================================================
; umul8x8 — Unsigned 8x8 -> 16-bit multiply (quarter-square)
; =====================================================================
;
; Inputs:   A      = unsigned multiplier  (0..255)
;           math_b = unsigned multiplicand (0..255)
; Outputs:  A = math_res_hi (high byte of product)
;           math_res_hi:math_res_lo = 16-bit unsigned product
; Clobbers: A, X, Y
;
; Cycles: ~57 including JSR/RTS.

umul8x8:
    ; -- Compute |a - b| --
    TAX                     ; cache A (first arg) in X
    SEC
    SBC math_b
    BCS @u_diff_pos
    EOR #$FF
    ADC #1                  ; C=0 from BCS not-taken
@u_diff_pos:
    TAY                     ; Y = |a - b|

    ; -- Compute (a + b) mod 256 --
    TXA                     ; restore first arg from X
    CLC
    ADC math_b
    TAX
    BCS @u_sum_overflow

    SEC
    LDA sqr_lo,X
    SBC sqr_lo,Y
    STA math_res_lo
    LDA sqr_hi,X
    SBC sqr_hi,Y
@u_done:
    STA math_res_hi          ; A = math_res_hi
    RTS

@u_sum_overflow:
    SEC
    LDA sqr2_lo,X
    SBC sqr_lo,Y
    STA math_res_lo
    LDA sqr2_hi,X
    SBC sqr_hi,Y
    BCS @u_done               ; C=1 always; share STA+RTS

; =====================================================================
; smul8x8 — Signed 8x8 -> 16-bit multiply (quarter-square)
; =====================================================================
;
; Inputs:   A      = signed multiplier  (-128..+127)
;           math_b = signed multiplicand (-128..+127)
; Outputs:  A = math_res_hi (high byte of product)
;           math_res_hi:math_res_lo = signed 16-bit product
; Clobbers: A, X, Y
;
; Cycles: ~62.

smul8x8:
    ; -- Compute |a - b| --
    STA math_a              ; store for sign correction
    TAX                     ; cache first arg in X
    SEC
    SBC math_b
    BCS @diff_pos
    EOR #$FF
    ADC #1                  ; C=0 from BCS not-taken
@diff_pos:
    TAY

    ; -- Compute (a + b) mod 256 --
    TXA                     ; restore first arg from X
    CLC
    ADC math_b
    TAX
    BCC @no_overflow

    SEC
    LDA sqr2_lo,X
    SBC sqr_lo,Y
    STA math_res_lo
    LDA sqr2_hi,X
    SBC sqr_hi,Y
    BCS @sign_correct         ; C=1 always (quarter-square never borrows)

@no_overflow:
    SEC
    LDA sqr_lo,X
    SBC sqr_lo,Y
    STA math_res_lo
    LDA sqr_hi,X
    SBC sqr_hi,Y

@sign_correct:
    ; C=1: quarter-square subtraction never borrows
    LDX math_a
    BPL @a_pos
    SBC math_b
@a_pos:
    LDX math_b
    BPL @done
    SEC
    SBC math_a
@done:
    STA math_res_hi
    RTS

; =====================================================================
; recip8 — Compute floor(32768 / z) for 16-bit z, 8-bit result
; =====================================================================
;
; Input:    A = z_hi, math_b = z_lo
; Output:   A = floor(32768 / z), 8-bit (0..128)
; Clobbers: A, X, Y
;
; Guard: if z_hi = 0, returns 0 (z < 256 → result > 128, too close).
; Normalise z_hi:z_lo left until bit 7 of A set, counting shifts in X.
; Index = A & $7F into recip_norm table, then right-shift by X.

recip8:
    CMP #1                  ; z_hi >= 1?
    BCS @ok
    LDA #0                  ; z < 256: return 0
    RTS
@ok:
    LDX #7
@norm:
    DEX
    ASL math_b
    ROL A
    BPL @norm
    AND #$7F
    TAY
    LDA recip_norm,Y
@shift:
    DEX
    BMI @done
    LSR A
    BPL @shift                ; always taken (LSR clears bit 7)
@done:
    RTS

recip_norm:
.repeat 128, i
    .byte 16384 / (128 + i)
.endrepeat
