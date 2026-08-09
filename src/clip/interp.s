; ============================================================================
; clip/interp.s — clipper fragment 4 of 10 (module map: clip/header.s).
; Contents: interp_store — u8 round-to-nearest line
; interpolation — and its umul_round_div helper (umul8 inlined there
; 2026-08-09; the div still tail-calls udiv16_8 in clip/arith.s).
; ============================================================================

; (pad removed after udiv16_8)

; (seg_interp_store + smul8 removed — replaced by u8 interp_store with Y_BIAS)

; ======================================================================
; INTERP_STORE: interpolate Y at column X (u8 result)
;
; Used for both old span boundaries AND new seg boundaries (with Y_BIAS,
; all Y values are u8).  Direction-split: always unsigned multiply |dy|.
; Caller pre-computes den = xhi - xlo once per span and reuses it
; for all 4 boundary interps (tl, tr, bl, br).
; Callers (2026-07-12): dcl.s (dcl_vertical top/bot eval + the CB-clip
; boundary evals), tfr.s (record-line and pool-line interps), and the
; harness (by symbol).
;
; Input: A = x (eval point), zp_i_x0, zp_i_y0, zp_i_y1, zp_div_den
;        (den = xhi - xlo; caller guarantees 0 <= x - x0 <= den, den > 0
;        except when x == x0, which early-exits before the divide)
; Output: A = interpolated Y (u8).  Clobbers X,Y and the mul/div ZP
;        working set (zp_mul_b, zp_prod_l/hi = zp_div_l/hi).
;
; Python mirror: endpoint_spans._interp_store (verified bit-exact).
; Rounds to nearest, half AWAY FROM ZERO (the +den//2 bias is applied
; to the unsigned |dy| product, then the quotient is added/subtracted).
;
; pseudocode:
;   offset = x - x0
;   if offset == 0:   return y0            # also y1 == y0 short-circuit
;   if offset == den: return y1
;   if y1 >= y0: return y0 + (offset*(y1-y0) + den//2) // den
;   else:        return y0 - (offset*(y0-y1) + den//2) // den
;
; Cost: 1 umul8 (8x8->16) + 1 udiv16_8; critical path = mul + div.
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
; ASCENDING (y1 > y0): dy = y1 - y0 (unsigned; C=1 proven — the
; direction CMP took neither BEQ nor BCC)
   SBC zp_i_y0
; |
   JSR umul_round_div                      ; |
   CLC
   ADC zp_i_y0
   RTS
; | y0 + quot
descending:
; DESCENDING (y1 < y0): |dy| = y0 - y1 via complement — A still holds
; y1 from the direction CMP: ~y1 + y0 + 1
   EOR #$FF
   SEC
   ADC zp_i_y0
; |
   JSR umul_round_div                      ; |
; y0 - quot via two's complement: A = ~quot, then ADC y0 with C=1
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

; ======================================================================
; UMUL_ROUND_DIV: shared helper — inlined umul8 + round bias + udiv16_8
; tail-call.
;
; Computes  quot = (|dy| * offset + den//2) / den  entirely unsigned.
; The caller's direction split (ascending/descending above) turns this
; into the half-away-from-zero rounding of _interp_store.
;
; Input:  A = |dy| (u8), zp_mul_b = offset (u8), zp_div_den = den (u8)
; Output: A = quotient (u8). Product always positive.
;         Clobbers X, Y and zp_prod_l/hi (= zp_div_l/hi).
; pseudocode:
;   prod = |dy| * offset          # umul8 -> zp_prod (u16)
;   prod += den >> 1              # round-to-nearest bias
;   return prod / den             # udiv16_8 (tail-called, its RTS
;                                 # returns to OUR caller)
; ======================================================================
umul_round_div:
.scope
; umul8 INLINED (2026-08-09 — this one site carries HALF of all umul8
; traffic, 35 calls/frame; the JSR/RTS was 417 cyc/frame). Identical
; quarter-square math on the same SQR_* tables (abi.inc — main RAM,
; reachable from bank C). Each sum arm carries its own rounding tail so
; the common sum<256 arm keeps umul8's zero-overhead fall-through; the
; rare round-carry bump is shared (ip_rn_c).
   TAX                                     ; stash |dy| in X
   SEC
   SBC zp_mul_b
   BCS ip_pos
   EOR #$FF
   ADC #1                                  ; |dy - offset| (C=0 from SBC)
ip_pos:
   TAY                                     ; Y = |diff|
   TXA
   CLC
   ADC zp_mul_b
   TAX                                     ; X = sum & $FF
   BCS ip_uo                               ; sum >= 256: sqr2 tables
   LDA SQR_LO,X
   SEC
   SBC SQR_LO,Y
   STA zp_prod_l
   LDA SQR_HI,X
   SBC SQR_HI,Y
   STA zp_prod_h
; 16-bit add of den//2 into the product (prod aliases the div dividend)
   LDA zp_div_den
   LSR A
   CLC
   ADC zp_prod_l
   STA zp_prod_l
   BCS ip_rn_c                             ; round-carry rare (3.6% —
   JMP udiv16_8                            ; census 2026-07-27)
ip_uo:
   LDA SQR2_LO,X                           ; (carry already set from BCS)
   SBC SQR_LO,Y
   STA zp_prod_l
   LDA SQR2_HI,X
   SBC SQR_HI,Y
   STA zp_prod_h
   LDA zp_div_den                          ; per-arm rounding tail (keeps
   LSR A                                   ; the hot arm fall-through)
   CLC
   ADC zp_prod_l
   STA zp_prod_l
   BCS ip_rn_c
   JMP udiv16_8
ip_rn_c:
   INC zp_prod_h
   JMP udiv16_8                            ; tail-call
.endscope
