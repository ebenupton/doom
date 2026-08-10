; ============================================================================
; bsp/arith.s — renderer-local arithmetic primitives.
;
; CONTEXT: everything here is a leaf (or thunk) under the seg pipeline.
;   br_umul8 / br_smul8       u8xu8 / s8xs8 via the shared quarter-square
;                             core umul8 (bsp/header.s, sqr tables —
;                             banked $1C00 / flat $A500, abi SQR_*).
;   br_recip                  (M8,S) reciprocal from the 9.1 depth index;
;                             every zp_br_r_s write is followed by an
;                             rns re-select (see project.s RNS banner).
;   br_frac_rot_term          per-frame fractional rotation term
;                             (br_view_setup only).
;   rot_zero/unity_pos/unity_neg/rot_gen_sin/rot_gen_cos + rot_core_sin/_cos
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
;   Output:  zp_br_res_l/resh (u16)
;   Uses:    umul8, the shared quarter-square multiplier
;            (a*b = f(a+b) - f(a-b), f(x) = x^2/4 table lookup);
;            clobbers zp_mul_b, zp_prod_l/hi, zp_tmp0, X, Y.
; Thin adapter from the br_a/br_b register convention onto umul8.
; ============================================================================
SEG_CODE
br_umul8:
   LDA zp_br_b
   STA zp_mul_b
   LDA zp_br_a
   JSR umul8
   STA zp_br_res_h                          ; A = prod_hi (umul8 contract)
   LDA zp_prod_l
   STA zp_br_res_l
   RTS

SEG_CODE
; ============================================================================
; br_smul8 — signed s8 × s8 → s16. Inputs in zp_br_a, zp_br_b.
; Result in zp_br_res_l/resh (s16, 2's complement). ~80 cycles.
;
; Sign-magnitude wrapper over the unsigned quarter-square core:
;   sign = (a < 0) ^ (b < 0);  a = |a|;  b = |b|
;   res  = umul8(a, b)                        (u8 × u8 → u16)
;   if sign: res = -res                          (16-bit negate)
; (br_smul_s8_u8 — a signed, b unsigned full 0..255 — is the clipper
; unit's variant; THIS one treats BOTH operands as s8.)
; Clobbers zp_br_a/b (replaced by magnitudes), zp_br_sign, zp_mul_b,
; zp_prod_l/hi, zp_tmp0, X, Y.
; (br_smul8 deleted 2026-07-16: zero engine callers — the last one
; died with the raw-product point_on_side cascade.)

; ============================================================================
; br_recip — floating-mantissa reciprocal lookup.
;   Input:  zp_br_t0:t1 = u16 vy_idx (9.1 format).
;   Output: zp_br_r_m8 = M8 (mantissa byte), zp_br_r_s = S (shift, 1..10):
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
; (br_recip_hi moved to clip/rotvar.s 2026-08-09 — see above.)
; SRECIP: 256-byte junior-page S table — ASSEMBLED data in the CODE
; region (main RAM: bank-independent, no loader involvement; the first
; flat placement at $1A00 sat on the RCACHE psi plane and rotcache
; caught it). Static and map-independent (src/srecip.inc, generated).
.segment "LDATA"                            ; $1E00 DATA-ONLY region (the
                                            ; LCODE island died 2026-08-09:
                                            ; one contiguous code area rule)
::RECIP_S:                                 ; (read by the inlined junior
.include "srecip.inc"                       ; arm at nc_ok, under L2;
                                            ; NIBBLE-SWAPPED layout — see
                                            ; the .inc header)
SEG_CODE
SEG_CODE

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
; lo, no multiply. Clobbers zp_mul_b, zp_prod_l/hi, zp_tmp0, X, Y.
; ============================================================================
zp_ft_lo = $07FB                        ; bitmap-page tail — REAL RAM both
zp_ft_mag = $07FC                       ; builds. WAS $E4F8-$E4FB (2026-07-27
zp_ft_neg = $07FD                       ; flat recovery) = OS ROM on the
zp_ft_one = $07FE                       ; REAL banked machine: the stores
                                        ; vanished, ft read constant ROM
                                        ; bytes, the fracs froze, and the
                                        ; viewpoint STAIRCASED a whole unit
                                        ; at every integer crossing — the
                                        ; quantised-jumping regression
                                        ; (2026-08-10, Eben's static-step
                                        ; repro; every harness models
                                        ; $E4F8 as RAM so every gate was
                                        ; blind — jsbeeb/HW only). Old note:
                                        ; ($E4F8-$E4FB
                                        ; sits in the proven-free VATOX tail)

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
   JSR umul8                            ; prod_lo:hi = lo * mag
; val = (prod + 128) >> 8 — round-to-nearest, then take HI byte.
   LDA zp_prod_l
   CLC
   ADC #128
   LDA zp_prod_h
   ADC #0
; A = HI byte after rounding
ft_apply_neg:
; A = u8 magnitude. Promote to s16 in zp_br_res_l:resh.
   STA zp_br_res_l
   ZERO zp_br_res_h
   LDA zp_ft_neg
   BEQ ft_done
   LDA #0
   SEC
   SBC zp_br_res_l
   STA zp_br_res_l
   LDA #0
   SBC zp_br_res_h
   STA zp_br_res_h
ft_done:
   RTS
ft_zero:
   LDA #0
   STA zp_br_res_l
   STA zp_br_res_h
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
;   Inputs:  zp_ri_d_l, zp_ri_d_h (s16 integer delta — was s8, now s16)
;            zp_ri_mag (u8 trig magnitude)
;            zp_br_t1 (seeded 1 if trig negative — thunk SMC)
;            zp_ri_one (1 if |trig| == 1)
;   Output:  zp_br_res_l/resh (s16)
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
; dy·sin. Clobbers zp_ri_d_l/dhi (replaced by |d|), zp_br_t1,
; zp_mul_b, zp_prod_l/hi, zp_tmp0, X, Y.
; ============================================================================
; ($29, $2B were unused zp_ri_mag/zp_ri_one -> reclaimed for zp_seg_bfh/bch)
zp_ri_d = zp_ri_d_l                     ; backwards-compat alias

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
;                                       rot_core_sin/_cos (per-trig: SMC sum bases)
; Same pattern as the bca_check_op / vxc_jsr_site / D-cache frame hooks.
; All variants are bit-exact with the old in-body branches.
; (rot variant entries moved to clip/rotvar.s 2026-08-09 — the LCODE
;  island died: one contiguous code area; the clip object join pad
;  absorbs them.)


SEG_CODE
; rot_core_sin/_cos — the general |d|*mag s24 path, ONE CORE PER TRIG
; because the sum-side quarter-square lookups carry the frame's mag in
; their SMC'd table-base operands (sin and cos have different mags).
; In: zp_ri_d_l/dhi = d (s16), zp_mul_b = mag (staged by the thunk; the
;     DIFF side still needs it), zp_br_t1 = trig sign seed (thunk).
; Out: resl/resh (s16 view COUNTS — 5-bit mag5 operands since
;      2026-08-10; the ext byte died). |d| written back to zp_ri_d_l/dhi.
rot_core_sin:
.scope
; d==0 -> both products are exactly zero (axis-aligned vertex deltas are
; common on E1M1's grid geometry) — skip the two multiplies.
   LDA zp_ri_d_l
   ORA zp_ri_d_h
   BEQ ris_zero                            ; d==0 rare (census 0.4%): direct
                                           ; hop to the zero tail below; the
                                           ; common case FALLS THROUGH
                                           ; (branch census 2026-07-27)
; ri_d arrives as |d| (caller-staged; d-sign folded into t1 by the
; thunk's EOR zp_ri_sgn) — the old in-place abs died 2026-07-19.
; --- lo*mag via quarter-squares, mag FOLDED INTO THE TABLE BASE ---
; The sum side f(x+mag) is one LDA abs,X with X = raw x: rot_select
; patches the operand LO byte to mag (SQR pages are page-aligned so the
; hi byte is static; the abs,X page-cross walks into the second lo/hi
; page — pages are CONTIGUOUS per gen_abi's 2026-07-12 reorder). No sum
; add, no TAX, no carry-window branch. Diff side is classic: |x-mag|
; always fits the first window.
   LDA zp_ri_d_l
   TAX                                     ; X = raw x (base carries +mag)
   SEC
   SBC zp_mul_b
   BCS um1_pos
   EOR #$FF
   ADC #1
um1_pos:
   TAY
::rot_sqs1l:
   LDA sqr_l,X                            ; +1 SMC = mag (rot_select)
   SEC
   SBC sqr_l,Y
   STA zp_rs_l                             ; sin side -> the rs slots
::rot_sqs1h:
   LDA sqr_h,X                            ; +1 SMC = mag (rot_select)
   SBC sqr_h,Y
   STA zp_rs_h                             ; (s16: mag5 products — the ext
                                           ; byte DIED with count-native)
; --- hi partial: |d| hi byte is 0..2 on this map (10-bit world coords;
; measured 87% zero, ~13% one) — multiply-by-0/1 dispatch to trivial
; arms; the general quarter-square stays as the >=2 fallback so NO
; delta-range fence is needed (any map/position stays exact). ---
   LDA zp_ri_d_h
   BNE s_hi_nz                             ; x1/x>=2 rare (13% claimed, 0 on
                                           ; suite): block hoisted past the
                                           ; tails. x0 FALLS INTO ris_sign —
                                           ; the old BEQ+JMP paid 6 cycles
                                           ; on a 100%-taken path (census)
.endscope

; sin negate/zero tails — MOVED ABOVE the cores' rare blocks 2026-07-27
; so the dominant x0 hi-partial falls straight in (branch census).
ris_sign:
   LDA zp_br_t1
   BEQ ris_done                            ; t1 = (d<0) XOR (trig<0)
   LDA #0
   SEC
   SBC zp_rs_l
   STA zp_rs_l
   LDA #0
   SBC zp_rs_h
   STA zp_rs_h
ris_done:
   RTS
ris_zero:
; A = 0 on entry (the d==0 BEQ path)
   STA zp_rs_l
   STA zp_rs_h
   RTS

; --- sin hi-partial rare block (x != 0), hoisted below the tails.
; File-local labels: the core's scope ends at the dispatch above. ---
s_hi_nz:
   CMP #1
   BEQ s_one                               ; x1: product == mag
   TAX
   SEC
   SBC zp_mul_b
   BCS s_um2_pos
   EOR #$FF
   ADC #1
s_um2_pos:
   TAY
::rot_sqs2l:
   LDA sqr_l,X                            ; +1 SMC = mag (rot_select)
   SEC
   SBC sqr_l,Y                            ; x*mag5 <= 93: the low-byte
   CLC                                    ; difference IS the product
   ADC zp_rs_h                            ; (mod-256 exact; the _h lookup
   STA zp_rs_h                            ; pair DIED with count-native —
   JMP ris_sign                           ; no carry: h <= 30 + 93 < 128)
s_one:
   LDA zp_mul_b                            ; rs_h += mag5 (no carry: see
   CLC                                     ; the general arm's bound)
   ADC zp_rs_h
   STA zp_rs_h
   JMP ris_sign

rot_core_cos:
.scope
; d==0 -> both products are exactly zero (axis-aligned vertex deltas are
; common on E1M1's grid geometry) — skip the two multiplies.
   LDA zp_ri_d_l
   ORA zp_ri_d_h
   BEQ ri_zero                             ; d==0 rare: direct hop to the
                                           ; zero tail; common FALLS THROUGH
                                           ; (branch census 2026-07-27)
::rot_core_cos_nz:                      ; pair-variant entry: d != 0 already
                                        ; established, staging done (t1/mul_b)
; ri_d arrives as |d| (caller-staged; d-sign folded into t1 by the
; thunk's EOR zp_ri_sgn) — the old in-place abs died 2026-07-19.
; --- lo*mag via quarter-squares, mag FOLDED INTO THE TABLE BASE ---
; The sum side f(x+mag) is one LDA abs,X with X = raw x: rot_select
; patches the operand LO byte to mag (SQR pages are page-aligned so the
; hi byte is static; the abs,X page-cross walks into the second lo/hi
; page — pages are CONTIGUOUS per gen_abi's 2026-07-12 reorder). No sum
; add, no TAX, no carry-window branch. Diff side is classic: |x-mag|
; always fits the first window.
   LDA zp_ri_d_l
   TAX                                     ; X = raw x (base carries +mag)
   SEC
   SBC zp_mul_b
   BCS um1_pos
   EOR #$FF
   ADC #1
um1_pos:
   TAY
::rot_sqc1l:
   LDA sqr_l,X                            ; +1 SMC = mag (rot_select)
   SEC
   SBC sqr_l,Y
   STA zp_br_res_l
::rot_sqc1h:
   LDA sqr_h,X                            ; +1 SMC = mag (rot_select)
   SBC sqr_h,Y
   STA zp_br_res_h                         ; (s16 — see the sin core)
; --- hi partial: |d| hi byte is 0..2 on this map (10-bit world coords;
; measured 87% zero, ~13% one) — multiply-by-0/1 dispatch to trivial
; arms; the general quarter-square stays as the >=2 fallback so NO
; delta-range fence is needed (any map/position stays exact). ---
   LDA zp_ri_d_h
   BNE c_hi_nz                             ; x1/x>=2 rare: block hoisted
                                           ; past the tails. x0 FALLS INTO
                                           ; ri_sign — the old BEQ was a
                                           ; 100%-taken page-crossing hop
.endscope                                  ; (branch census 2026-07-27)

; cos negate/zero tails: the dominant x0 hi-partial falls straight in.
ri_sign:                                    ; entry for the x0/x1 arms
   LDA zp_br_t1
   BEQ ri_done                             ; t1 = (d<0) XOR (trig<0)
   LDA #0
   SEC
   SBC zp_br_res_l
   STA zp_br_res_l
   LDA #0
   SBC zp_br_res_h
   STA zp_br_res_h
ri_done:
   RTS
ri_zero:
; A = 0 on entry (the d==0 BEQ path)
   STA zp_br_res_l
   STA zp_br_res_h
   RTS

; --- cos hi-partial rare block (x != 0), hoisted below the tails.
; (The sin twins moved up beside the sin core — res-slot split means
; duplication, not SMC: both cores run within one frame.) ---
c_hi_nz:
   CMP #1
   BEQ c_one                               ; x1: product == mag
   TAX
   SEC
   SBC zp_mul_b
   BCS c_um2_pos
   EOR #$FF
   ADC #1
c_um2_pos:
   TAY
::rot_sqc2l:
   LDA sqr_l,X                            ; +1 SMC = mag (rot_select)
   SEC
   SBC sqr_l,Y                            ; 1-byte product (see sin core)
   CLC
   ADC zp_br_res_h
   STA zp_br_res_h
   JMP ri_sign
c_one:
   LDA zp_mul_b                            ; resh += mag5 (no carry)
   CLC
   ADC zp_br_res_h
   STA zp_br_res_h
   JMP ri_sign

; ============================================================================
; rot_core_cosv_nz — the fused pair's cos half, VY DESTINATIONS
; (2026-07-27 direct-write: res-slot-split precedent — duplication,
; not SMC; the standalone cos core keeps zp_br_res for the s2 site).
; Entered ONLY from rot_gen_pair's p_cos (d != 0 already established,
; mul_b/t1 staged). rot_select patches the four rot_sqcv* operands
; alongside the sqc ones. Same x0-falls-into-sign arrangement as the
; parent (branch census 2026-07-27).
; ============================================================================
.scope
::rot_core_cosv_nz:
   LDA zp_ri_d_l
   TAX
   SEC
   SBC zp_mul_b
   BCS cv1_pos
   EOR #$FF
   ADC #1
cv1_pos:
   TAY
::rot_sqcv1l:
   LDA sqr_l,X                            ; +1 SMC = |cos| mag (rot_select)
   SEC
   SBC sqr_l,Y
   STA zp_br_vy_l
::rot_sqcv1h:
   LDA sqr_h,X                            ; +1 SMC = |cos| mag (rot_select)
   SBC sqr_h,Y
   STA zp_br_vy_h                          ; (s16 — see the sin core)
   LDA zp_ri_d_h
   BNE cv_hi_nz                            ; x1/x>=2 rare: block below
rivsign:
   LDA zp_br_t1
   BEQ rivdone                             ; t1 = (d<0) XOR (trig<0)
   LDA #0
   SEC
   SBC zp_br_vy_l
   STA zp_br_vy_l
   LDA #0
   SBC zp_br_vy_h
   STA zp_br_vy_h
rivdone:
   RTS
cv_hi_nz:
   CMP #1
   BEQ cv_one                              ; x1: product == mag
   TAX
   SEC
   SBC zp_mul_b
   BCS cv2_pos
   EOR #$FF
   ADC #1
cv2_pos:
   TAY
::rot_sqcv2l:
   LDA sqr_l,X                            ; +1 SMC = |cos| mag (rot_select)
   SEC
   SBC sqr_l,Y                            ; 1-byte product (see sin core)
   CLC
   ADC zp_br_vy_h
   STA zp_br_vy_h
   JMP rivsign
cv_one:
   LDA zp_mul_b                            ; vy_h += mag5 (no carry)
   CLC
   ADC zp_br_vy_h
   STA zp_br_vy_h
   JMP rivsign
.endscope


; ============================================================================
; rot_gen_pair — the FUSED dx-pair rotate (2026-07-19): one JSR runs
; sin*d -> zp_rs AND cos*d -> zp_br_res, sharing the d==0 test and one
; call/return round (was two JSR/RTS pairs and two tests). rot_select
; patches the rot_s13 site to this variant when BOTH trigs are general;
; axis-aligned frames get rot_pair_thunk below (+3 cycles, rare). The
; sin half is a private copy of rot_core_sin (rgp_* SMC operands, local
; finish/sign tails that FALL THROUGH); the cos half stages and enters
; the SHARED core past its d==0 test — its RTS returns to our caller.
; Segment RPAIR: flat loads in the ANG region (resident, cycle-neutral
; — flat has no banking), banked in CODE.
; ============================================================================
SEG_CODE
rot_gen_pair:
.scope
   LDA zp_ri_d_l
   ORA zp_ri_d_h
   BEQ p_zero                              ; d==0 rare: zero block sits
                                           ; past p_cos; common FALLS
                                           ; THROUGH (census 2026-07-27)
; --- sin half: gen_sin's staging + core body, rs dests ---
::rgp_smag:
   LDA #0                                  ; +1 SMC: |sin| mag (rot_select)
   STA zp_mul_b
::rgp_sneg:
   LDA #0                                  ; +1 SMC: sin neg flag
   EOR zp_ri_sgn
   STA zp_br_t1
   LDA zp_ri_d_l
   TAX                                     ; X = raw x (base carries +mag)
   SEC
   SBC zp_mul_b
   BCS p_um1_pos
   EOR #$FF
   ADC #1
p_um1_pos:
   TAY
::rgp_sq1l:
   LDA sqr_l,X                            ; +1 SMC = mag (rot_select)
   SEC
   SBC sqr_l,Y
   STA zp_rs_l
::rgp_sq1h:
   LDA sqr_h,X                            ; +1 SMC = mag (rot_select)
   SBC sqr_h,Y
   STA zp_rs_h                             ; (s16 — see the sin core)
   LDA zp_ri_d_h
   BNE p_hi_nz                             ; x1/x>=2 rare: block below
                                           ; p_zero; x0 FALLS INTO p_sgn
                                           ; (branch census 2026-07-27)
p_sgn:
; local ris_sign, FALLING THROUGH to the cos half
   LDA zp_br_t1
   BEQ p_cos                               ; t1 = (d<0) XOR (sin<0)
   LDA #0
   SEC
   SBC zp_rs_l
   STA zp_rs_l
   LDA #0
   SBC zp_rs_h
   STA zp_rs_h
p_cos:
; --- cos half: gen_cos's staging, then the shared core past its test ---
::rgp_cmag:
   LDA #0                                  ; +1 SMC: |cos| mag (rot_select)
   STA zp_mul_b
::rgp_cneg:
   LDA #0                                  ; +1 SMC: cos neg flag
   EOR zp_ri_sgn
   STA zp_br_t1
   JMP rot_core_cosv_nz                    ; VY-dest twin (2026-07-27): the
                                           ; fused pair writes vy DIRECTLY —
                                           ; the rot_s13 call-site copy died

p_zero:
   STA zp_rs_l                             ; A = 0: zero BOTH result sets
   STA zp_rs_h                             ; (cos side = vy since the
   STA zp_br_vy_l                          ; direct-write, 2026-07-27)
   STA zp_br_vy_h
   RTS

; --- pair sin-half hi-partial rare block (x != 0) ---
p_hi_nz:
   CMP #1
   BEQ p_one                               ; x1: product == mag
   TAX
   SEC
   SBC zp_mul_b
   BCS p_um2_pos
   EOR #$FF
   ADC #1
p_um2_pos:
   TAY
::rgp_sq2l:
   LDA sqr_l,X                            ; +1 SMC = mag (rot_select)
   SEC
   SBC sqr_l,Y                            ; 1-byte product (see sin core)
   CLC
   ADC zp_rs_h
   STA zp_rs_h
   JMP p_sgn
p_one:
   LDA zp_mul_b                            ; rs_h += mag5 (no carry)
   CLC
   ADC zp_rs_h
   STA zp_rs_h
   JMP p_sgn
.endscope

; (rot_pair_thunk moved to clip/rotvar.s 2026-08-09)
SEG_CODE
