; ============================================================================
; bsp/arith.s — renderer-local arithmetic primitives.
;
; CONTEXT: everything here is a leaf (or thunk) under the seg pipeline.
;   br_umul8 / br_smul8       u8xu8 / s8xs8 via the shared quarter-square
;                             core SC_UMUL8 (clip/arith.s, sqr tables —
;                             banked $1C00 / flat $A500, abi SQR_*).
;   br_recip                  (M8,S) reciprocal from the 9.1 depth index;
;                             every zp_br_rlo write is followed by an
;                             rns re-select (see project.s RNS banner).
;   br_frac_rot_term          per-frame fractional rotation term
;                             (br_view_setup only).
;   rot_zero/unity_pos/unity_neg/rot_gen_sin/rot_gen_cos + rot_core
;                             the SMC-specialized rotation variants:
;                             rot_select (view.s SEL segment) patches the
;                             four rot_s1..s4 call-site operands in
;                             br_to_view once per frame, plus the general
;                             thunks' mag + sign immediates. The trig
;                             sign SEEDS zp_br_t1 (thunk SMC); a negative
;                             d flips it; ONE tail negate (XOR fold,
;                             2026-07-11 — the old code double-negated).
; Callers: br_to_view (view.s) for the rot variants; seg_xform/lo/project
; for the muls; crossing + recip sites as documented per routine.
; ============================================================================

; ============================================================================
; br_umul8 — unsigned u8 × u8 → u16.
;   Inputs:  zp_br_a, zp_br_b (u8 each)
;   Output:  zp_br_resl/resh (u16)
;   Uses:    SC_UMUL8, the shared quarter-square multiplier
;            (a*b = f(a+b) - f(a-b), f(x) = x^2/4 table lookup);
;            clobbers zp_mul_b, zp_prod_lo/hi, zp_tmp0, X, Y.
; Thin adapter from the br_a/br_b register convention onto SC_UMUL8.
; ============================================================================
.if ::BANKED
.segment "W_BK"
; (historical segment split: W_BK floats inside the one CODE region in
; both builds since the 2026-07 merges — the placement notes that used
; to live here are obsolete; the segment name only orders the link.)
.endif
br_umul8:
   LDA zp_br_b
   STA zp_mul_b
   LDA zp_br_a
   JSR SC_UMUL8
   STA zp_br_resh                          ; A = prod_hi (umul8 contract)
   LDA zp_prod_lo
   STA zp_br_resl
   RTS

.if ::BANKED
.segment "MAIN"
.endif
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
   STA zp_br_resh                          ; A = prod_hi (umul8 contract)
   LDA zp_prod_lo
   STA zp_br_resl
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
; br_recip — floating-mantissa reciprocal lookup.
;   Input:  zp_br_t0:t1 = u16 vy_idx (9.1 format).
;   Output: zp_br_rhi = M8 (mantissa byte), zp_br_rlo = S (shift, 1..10):
;           FOCAL/vy = 256/idx ≈ (256 + M8) / 2^S.
;
; Algorithm (mirrors fp_recip, fp.py):
;   vy_idx clamped to [2, 1023].
;   M8 = RECIP_M8[vy_idx]           (direct 1024-entry byte table)
;   S  = bit_length(vy_idx - 1)     (computed — always normalizes m9 =
;                                    256+M8 into [256,511], no S table)
;
; The m9 mantissa carries 9 significant bits (implicit leading 1):
; relative error <= 2^-10 — on-screen coordinates land within 1/8 px,
; and anything below quarter-pixel is unobservable. This replaced the
; 8.8 fixed reciprocal + 16-bit adjacent-entry averaging (2026-07-08):
; direct lookup, and one fewer multiply in every projection consumer.
; One reciprocal serves both X and Y projection: the 1.2 aspect ratio
; is baked into height prescaling. Clobbers A, X, Y, zp_br_p/p_h.
; ============================================================================
.assert (RECIP_BASE & $FF) = 0, error   ; 4-page table indexed (page | t1)
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

; --- M8 = RECIP_M8[idx]: page = >RECIP_BASE + idx.hi, offset = idx.lo ---
   LDA #0
   STA zp_br_p
   LDA zp_br_t1
   CLC
   ADC #>RECIP_BASE
   STA zp_br_p_h
   LDY zp_br_t0
   LDA (zp_br_p),Y
   STA zp_br_rhi                           ; M8

; --- S = bit_length(idx - 1); idx >= 2 so idx-1 >= 1 ---
   LDA zp_br_t0
   SEC
   SBC #1
   TAX                                     ; X = lo(idx-1)
   LDA zp_br_t1
   SBC #0                                  ; A = hi(idx-1), in [0,3]
   BEQ s_scan_lo
   CMP #1
   BEQ s_9
   LDA #10                                 ; hi = 2 or 3 → top bit 9 → S = 10
   STA zp_br_rlo
   JMP rns_select                          ; pick the vectored shifter (RTSes)
s_9:
   LDA #9                                  ; hi = 1 → top bit 8 → S = 9
   STA zp_br_rlo
   JMP rns_select
s_scan_lo:
; bit_length of X (>= 1): descending compare cascade
   LDA #8
   CPX #128
   BCS s_have
   LDA #7
   CPX #64
   BCS s_have
   LDA #6
   CPX #32
   BCS s_have
   LDA #5
   CPX #16
   BCS s_have
   LDA #4
   CPX #8
   BCS s_have
   LDA #3
   CPX #4
   BCS s_have
   LDA #2
   CPX #2
   BCS s_have
   LDA #1                                  ; X == 1
s_have:
   STA zp_br_rlo                           ; S
   JMP rns_select                          ; pick the vectored shifter (RTSes)
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
;            zp_br_t1 (seeded 1 if trig negative — thunk SMC)
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
; dy·sin. Clobbers zp_ri_dlo/dhi (replaced by |d|), zp_br_t1,
; zp_mul_b, zp_prod_lo/hi, zp_tmp0, X, Y.
; ============================================================================
; ($29, $2B were unused zp_ri_mag/zp_ri_one -> reclaimed for zp_seg_bfh/bch)
zp_ri_d = zp_ri_dlo                     ; backwards-compat alias

; SMC rotation variants (2026-07-08): the trig config (one/mag/neg per
; sin/cos) is FRAME-CONSTANT, so the per-call tests and Y-indexed trig
; loads the old br_rot_int did ~200x/frame are hoisted into a per-frame
; specialization: rot_select (SEL region, bank C window) patches the four
; call-site JSR operands in br_to_view (rot_s1..rot_s4, view.s) to one of
;   rot_zero        mag == 0            result := 0
;   rot_unity_pos   |trig| == 1, +ve    result := d << 8
;   rot_unity_neg   |trig| == 1, -ve    result := -(d << 8)
;   rot_gen_sin/cos general             thunk stages the frame's mag/neg
;                                       as SMC'd immediates, falls into
;                                       rot_core (the old mul body)
; Same pattern as the jt_bca_check / vxc_jsr_site / D-cache frame hooks.
; All variants are bit-exact with the old in-body branches.
.if ::BANKED
.segment "B_BK"
; (banked: the rot variants live in B_BK — MAIN hit its ceiling when the
; back-face mul arm grew; they are vector/SMC targets, resident anywhere.)
.endif
rot_zero:
   LDA #0
   STA zp_br_resl
   STA zp_br_resh
   STA zp_br_resext
   RTS

rot_unity_pos:
; val = d << 8 as s24: resl=0, resh=dlo, resext=dhi.
   ZERO zp_br_resl
   LDA zp_ri_dlo
   STA zp_br_resh
   LDA zp_ri_dhi
   STA zp_br_resext
   RTS

rot_unity_neg:
; -(d << 8): byte 0 stays 0 (no borrow out of 0-0), negate the top pair.
   ZERO zp_br_resl
   LDA #0
   SEC
   SBC zp_ri_dlo
   STA zp_br_resh
   LDA #0
   SBC zp_ri_dhi
   STA zp_br_resext
   RTS

rot_gen_sin:
   LDA #0                                  ; SMC +1: |sin| mag (rot_select)
   STA zp_mul_b
   LDA #0                                  ; SMC +5: sin neg flag
   STA zp_br_t1                            ; SEEDS the core's sign tracker
   JMP rot_core

rot_gen_cos:
   LDA #0                                  ; SMC +1: |cos| mag (rot_select)
   STA zp_mul_b
   LDA #0                                  ; SMC +5: cos neg flag
   STA zp_br_t1                            ; SEEDS the core's sign tracker
   JMP rot_core

.if ::BANKED
.segment "MAIN"
.endif
; rot_core — the general |d|*mag s24 path (the old br_rot_int body).
; In: zp_ri_dlo/dhi = d (s16), zp_mul_b = mag (staged by the thunk),
;     zp_br_t1 = trig sign seed (thunk). Out: resl/resh/resext (s24).
; Clobbers as before (|d| written back to zp_ri_dlo/dhi).
rot_core:
.scope
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
; zp_br_t1 arrives SEEDED with the trig sign (thunk SMC immediate); a
; negative d FLIPS it — the d-sign and trig-sign negations XOR-fold into
; one tail negate (they used to double-negate when both fired).
   LDA zp_ri_dhi
   BPL ri_d_pos
   LDA zp_br_t1
   EOR #1
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
   TAX                                     ; stash in X (was zp_tmp0)
   SEC
   SBC zp_mul_b
   BCS um1_pos
   EOR #$FF
   ADC #1
um1_pos:
   TAY
   TXA
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
   TAX                                     ; stash in X (was zp_tmp0)
   SEC
   SBC zp_mul_b
   BCS um2_pos
   EOR #$FF
   ADC #1
um2_pos:
   TAY
   TXA
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
   BEQ ri_done                             ; t1 = (d<0) XOR (trig<0)
; net sign negative -> negate the s24 result ONCE.
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
ri_done:
   RTS
ri_zero:
   LDA #0
   STA zp_br_resl
   STA zp_br_resh
   STA zp_br_resext
   RTS
.endscope
