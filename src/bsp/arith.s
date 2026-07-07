; ============================================================================
; br_umul8 — unsigned u8 × u8 → u16.
;   Inputs:  zp_br_a, zp_br_b (u8 each)
;   Output:  zp_br_resl/resh (u16)
;   Uses:    SC_UMUL8, the shared quarter-square multiplier
;            (a*b = f(a+b) - f(a-b), f(x) = x^2/4 table lookup);
;            clobbers zp_mul_b, zp_prod_lo/hi, zp_tmp0, X, Y.
; Thin adapter from the br_a/br_b register convention onto SC_UMUL8.
; ============================================================================
br_umul8:
LDA zp_br_b
STA zp_mul_b
LDA zp_br_a
JSR SC_UMUL8
LDA zp_prod_lo
STA zp_br_resl
LDA zp_prod_hi
STA zp_br_resh
RTS

; ============================================================================
; br_smul8 — signed s8 × s8 → s16. Inputs in zp_br_a, zp_br_b.
; Result in zp_br_resl/resh (s16, 2's complement). ~80 cycles.
;
; Sign-magnitude wrapper over the unsigned quarter-square core:
;   sign = (a < 0) ^ (b < 0);  a = |a|;  b = |b|
;   res  = SC_UMUL8(a, b)                        (u8 × u8 → u16)
;   if sign: res = -res                          (16-bit negate)
; (br_smul_s8_u8 — a signed, b unsigned full 0..255 — is the clipper
; unit's variant; THIS one treats BOTH operands as s8.)
; Clobbers zp_br_a/b (replaced by magnitudes), zp_br_sign, zp_mul_b,
; zp_prod_lo/hi, zp_tmp0, X, Y.
; ============================================================================
br_smul8:
.scope
ZERO zp_br_sign
; |a|, track sign
LDA zp_br_a
BPL a_pos
EOR #$FF
BUMP
STA zp_br_a
INC zp_br_sign
a_pos:
LDA zp_br_b
BPL b_pos
EOR #$FF
BUMP
STA zp_br_b
LDA zp_br_sign
EOR #1
STA zp_br_sign
b_pos:
LDA zp_br_b
STA zp_mul_b
LDA zp_br_a
JSR SC_UMUL8
LDA zp_prod_lo
STA zp_br_resl
LDA zp_prod_hi
STA zp_br_resh
LDA zp_br_sign
BEQ pos
; Negate s16 result
LDA #0
SEC
SBC zp_br_resl
STA zp_br_resl
LDA #0
SBC zp_br_resh
STA zp_br_resh
pos:
RTS
.endscope

; ============================================================================
; br_recip — reciprocal lookup with 1-bit-fractional averaging.
;   Input:  zp_br_t0:t1 = u16 vy_idx (9.1 format).
;   Output: zp_br_rhi, zp_br_rlo.
;
; Algorithm:
;   vy_idx clamped to [2, 1023].
;   i = vy_idx >> 1.
;   frac = vy_idx & 1.
;   if !frac: return HI[i], LO[i].
;   else: 16-bit avg of (HI:LO[i], HI:LO[i+1]).
;
; Tables: HI[0..513] at $E000, LO[0..513] at $E202.
;
; Mirrors fp_recip (fp.py): HI:LO[i] = min((128 << 8) // i, $7FFF), the
; 8.8 perspective scale FOCAL/vy. The 9.1 input keeps one fractional bit
; of vy; averaging the two adjacent 16-bit entries (add + 17-bit shift,
; no multiply) resolves it. The average MUST be done on the reconstructed
; 16-bit values — averaging hi/lo bytes separately is catastrophically
; wrong when HI[i] != HI[i+1]. One reciprocal serves both X and Y
; projection: the 1.2 aspect ratio is baked into height prescaling.
; Clobbers zp_br_t0-t3 and zp_br_p/p_h.
; ============================================================================
br_recip:
.scope
PAGE BANK_L2                            ; recip table lives in bank L2
; --- Clamp vy_idx to [2, 1023] ---
LDA zp_br_t1
CMP #4
BCC c_hi_ok
LDA #$FF
STA zp_br_t0
LDA #3
STA zp_br_t1
c_hi_ok:
LDA zp_br_t1
BNE c_lo_ok
; HI > 0 → ≥ 256 ≥ 2, OK
LDA zp_br_t0
CMP #2
BCS c_lo_ok
LDA #2
STA zp_br_t0
c_lo_ok:

; --- Save the frac bit (LSB of vy_idx.LO) ---
LDA zp_br_t0
AND #1
STA zp_br_t2

; --- Compute i = vy_idx >> 1 (16-bit shift right) ---
; LSR HI, ROR LO. After LSR HI, carry holds old bit 0 of HI; ROR LO
; brings carry into LO bit 7. Result: i.HI in t1, i.LO in t0.
LSR zp_br_t1
ROR zp_br_t0

; --- Build pointer to HI[i] = $E000 + i ---
CLC
LDA zp_br_t0
ADC #<RECIP_BASE
STA zp_br_p
LDA zp_br_t1
ADC #>RECIP_BASE
STA zp_br_p_h

; --- HI[i] ---
LDY #0
LDA (zp_br_p),Y
STA zp_br_rhi

; --- LO[i] = HI[i] + 0x202 (= 514, table size) ---
; We can index the same pointer with Y=$202 — but that overflows u8 Y.
; Easier: build a second pointer for LO base.
CLC
LDA zp_br_t0
ADC #<(RECIP_BASE + 514)
STA zp_br_p
LDA zp_br_t1
ADC #>(RECIP_BASE + 514)
STA zp_br_p_h
LDA (zp_br_p),Y
STA zp_br_rlo

; --- If no averaging needed, done ---
LDA zp_br_t2
BNE r_avg
RTS

r_avg:
; --- Read HI[i+1] and LO[i+1], full 16-bit average with current ---
; Re-build LO pointer (currently set) and bump Y to 1.
LDY #1
LDA (zp_br_p),Y
STA zp_br_t3
; LO[i+1]

; HI[i+1]: rebuild pointer to HI base.
CLC
LDA zp_br_t0
ADC #<RECIP_BASE
STA zp_br_p
LDA zp_br_t1
ADC #>RECIP_BASE
STA zp_br_p_h
LDA (zp_br_p),Y                         ; HI[i+1]
STA zp_br_t2                            ; t2 = HI[i+1] (frac flag no longer needed)

; --- 16-bit average: ((HI[i]:LO[i]) + (HI[i+1]:LO[i+1])) >> 1 ---
CLC
LDA zp_br_rlo
ADC zp_br_t3
STA zp_br_t3
; sum.LO
LDA zp_br_rhi
ADC zp_br_t2
STA zp_br_t2
; sum.HI (carry=overflow bit)

; Shift right 17 bits (16-bit + 1 carry) by 1.
; ROR carries the overflow into bit 7 of HI.
ROR zp_br_t2
ROR zp_br_t3
LDA zp_br_t2
STA zp_br_rhi
LDA zp_br_t3
STA zp_br_rlo
RTS
.endscope

; ============================================================================
; HELPER: br_frac_rot_term — fractional rotation contribution.
;   Inputs:  zp_ft_lo  (u8 fractional delta)
;            zp_ft_mag (u8 trig magnitude)
;            zp_ft_neg (1 if trig is negative, else 0)
;            zp_ft_one (1 if |trig| == 1, else 0)
;   Output:  zp_resl/h (s16 in [-255, 255])
;
;   Python:
;     if unity: val = lo
;     elif mag == 0 or lo == 0: return 0
;     else: val = (lo*mag + 128) >> 8
;     return -val if neg else val
;
; Mirrors _frac_rot_term (fp.py). Called (up to) 4× per FRAME by
; br_view_setup (view.s) to build frac_vx/frac_vy — the rotation of the
; player position's fractional byte. Vertex fractions are always 0, so
; per-vertex work needs only the integer terms (br_rot_int below).
; unity = cardinal angle (|sin| or |cos| rounds to 1.0): exact copy of
; lo, no multiply. Clobbers zp_mul_b, zp_prod_lo/hi, zp_tmp0, X, Y.
; ============================================================================
zp_ft_lo = $0BF8                        ; absolute (swapped with zp_seg_lv1x/y); cold
zp_ft_mag = $0BF9
zp_ft_neg = $0BFA
zp_ft_one = $0BFB

br_frac_rot_term:
.scope
LDA zp_ft_one
BEQ ft_not_one
LDA zp_ft_lo
JMP ft_apply_neg
ft_not_one:
LDA zp_ft_mag
BEQ ft_zero
LDA zp_ft_lo
BEQ ft_zero
LDA zp_ft_mag
STA zp_mul_b
LDA zp_ft_lo
JSR SC_UMUL8                            ; prod_lo:hi = lo * mag
; val = (prod + 128) >> 8 — round-to-nearest, then take HI byte.
LDA zp_prod_lo
CLC
ADC #128
LDA zp_prod_hi
ADC #0
; A = HI byte after rounding
ft_apply_neg:
; A = u8 magnitude. Promote to s16 in zp_br_resl:resh.
STA zp_br_resl
ZERO zp_br_resh
LDA zp_ft_neg
BEQ ft_done
LDA #0
SEC
SBC zp_br_resl
STA zp_br_resl
LDA #0
SBC zp_br_resh
STA zp_br_resh
ft_done:
RTS
ft_zero:
LDA #0
STA zp_br_resl
STA zp_br_resh
RTS
.endscope

; ============================================================================
; HELPER: br_rot_int — integer rotation contribution (s16 × u8 → s16).
;
; Conceptually computes |d| × mag as u24, but only retains the low 16 bits.
; This is correct because the rotation matrix application sums 4 such
; terms with sign cancellation, and the final sum (total_vx, total_vy)
; fits s16 in practice for reasonable map sizes.
;
;   Inputs:  zp_ri_dlo, zp_ri_dhi (s16 integer delta — was s8, now s16)
;            zp_ri_mag (u8 trig magnitude)
;            zp_ri_neg (1 if trig negative)
;            zp_ri_one (1 if |trig| == 1)
;   Output:  zp_br_resl/resh (s16)
;
;   Python:
;     if unity: val = d_hi << 8
;     else if mag == 0: return 0
;     else: val = m8(d_hi, mag)
;     return -val if neg else val
;
; Mirrors _rot_int (fp.py), widened: d is now the full s16 world-space
; delta (wx - px_int), so the result is s24 in resl/resh/resext — the
; 8.8 view coordinate plus a sign/overflow extension byte. Called 4× per
; vertex-cache miss by br_to_view (view.s): dx·sin, dy·cos, dx·cos,
; dy·sin. Clobbers zp_ri_dlo/dhi (replaced by |d|), zp_ri_neg, zp_br_t1,
; zp_mul_b, zp_prod_lo/hi, zp_tmp0, X, Y.
; ============================================================================
; ($29, $2B were unused zp_ri_mag/zp_ri_one -> reclaimed for zp_seg_bfh/bch)
zp_ri_d = zp_ri_dlo                     ; backwards-compat alias

; br_rot_int — Y = 0 (sin) or 3 (cos); mag/neg/one are read directly
; from the contiguous trig ZP block at $05 (smag,sneg,sone,cmag,cneg,cone)
; via abs,Y. Callers no longer stage zp_ri_mag/neg/one. neg is captured
; up front because SC_UMUL8 clobbers Y.
br_rot_int:
.scope
LDA $0006,Y
STA zp_ri_neg
LDA $0007,Y
BEQ ri_not_one
; Unity: val = d << 8 as s24. resl=0, resh=dlo, resext=dhi.
ZERO zp_br_resl
LDA zp_ri_dlo
STA zp_br_resh
LDA zp_ri_dhi
STA zp_br_resext
JMP ri_apply_neg
ri_not_one:
LDA $0005,Y
BNE ri_mag_nz
JMP ri_zero
; (ri_zero now >127 away after inline)
ri_mag_nz:
STA zp_mul_b
; d==0 -> both products are exactly zero (axis-aligned vertex deltas are
; common on E1M1's grid geometry) — skip the two multiplies.
LDA zp_ri_dlo
ORA zp_ri_dhi
BNE ri_d_nz
JMP ri_zero
ri_d_nz:
; |d| × mag → s24, with sign restoration. Compute as
;   res = |d|.lo * mag + (|d|.hi * mag) << 8.
; First product: (lo,hi) → resl, resh; resext starts 0.
; Second product: (lo,hi) added to resh, resext.
ZERO zp_br_t1                           ; sign tracker (1 if d was -ve)
LDA zp_ri_dhi
BPL ri_d_pos
LDA #1
STA zp_br_t1
LDA #0
SEC
SBC zp_ri_dlo
STA zp_ri_dlo
LDA #0
SBC zp_ri_dhi
STA zp_ri_dhi
ri_d_pos:
; --- inlined umul8(zp_ri_dlo, mag) — saves JSR/RTS in the hot rotation ---
; Quarter-square multiply: a*b = f(a+b) - f(|a-b|), f(x) = x²/4 tables.
; X = a+b (sqr2_* tables when the sum carries past 255), Y = |a-b|.
LDA zp_ri_dlo
STA zp_tmp0
SEC
SBC zp_mul_b
BCS um1_pos
EOR #$FF
ADC #1
um1_pos:
TAY
LDA zp_tmp0
CLC
ADC zp_mul_b
TAX
BCS um1_uo
LDA sqr_lo,X
SEC
SBC sqr_lo,Y
STA zp_br_resl
LDA sqr_hi,X
SBC sqr_hi,Y
STA zp_br_resh
JMP um1_done
um1_uo:
LDA sqr2_lo,X
SBC sqr_lo,Y
STA zp_br_resl
LDA sqr2_hi,X
SBC sqr_hi,Y
STA zp_br_resh
um1_done:
ZERO zp_br_resext
; --- inlined umul8(zp_ri_dhi, mag) — same quarter-square pattern; its
; u16 product lands one byte up: added into resh (lo) and resext (hi). ---
LDA zp_ri_dhi
STA zp_tmp0
SEC
SBC zp_mul_b
BCS um2_pos
EOR #$FF
ADC #1
um2_pos:
TAY
LDA zp_tmp0
CLC
ADC zp_mul_b
TAX
BCS um2_uo
LDA sqr_lo,X
SEC
SBC sqr_lo,Y
STA zp_prod_lo
LDA sqr_hi,X
SBC sqr_hi,Y
STA zp_prod_hi
JMP um2_done
um2_uo:
LDA sqr2_lo,X
SBC sqr_lo,Y
STA zp_prod_lo
LDA sqr2_hi,X
SBC sqr_hi,Y
STA zp_prod_hi
um2_done:
CLC
LDA zp_prod_lo
ADC zp_br_resh
STA zp_br_resh
LDA zp_prod_hi
ADC zp_br_resext
STA zp_br_resext
LDA zp_br_t1
BEQ ri_apply_neg
; d was negative → negate s24 result.
LDA #0
SEC
SBC zp_br_resl
STA zp_br_resl
LDA #0
SBC zp_br_resh
STA zp_br_resh
LDA #0
SBC zp_br_resext
STA zp_br_resext
ri_apply_neg:
LDA zp_ri_neg
BNE ri_do_neg                           ; rare (trig negative); common case
ri_done:                                ; falls straight through to RTS
RTS
ri_do_neg:
LDA #0
SEC
SBC zp_br_resl
STA zp_br_resl
LDA #0
SBC zp_br_resh
STA zp_br_resh
LDA #0
SBC zp_br_resext
STA zp_br_resext
RTS
ri_zero:
LDA #0
STA zp_br_resl
STA zp_br_resh
STA zp_br_resext
RTS
.endscope
