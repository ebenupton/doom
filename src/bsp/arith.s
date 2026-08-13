; ============================================================================
; bsp/arith.s — renderer-local arithmetic primitives.
;
; CONTEXT: everything here is a leaf (or thunk) under the seg pipeline.
;   umul8_zp / br_smul8       u8xu8 / s8xs8 via the shared quarter-square
;                             core umul8 (bsp/header.s, sqr tables —
;                             banked $1C00 / flat $A500, abi SQR_*).
;   br_recip                  (M8,S) reciprocal from the 9.1 depth index;
;                             every zp_br_r_s write is followed by an
;                             rns re-select (see project.s RNS banner).
;   frac_rot_term          per-frame fractional rotation term
;                             (view_setup only).
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
; umul8_zp — unsigned u8 × u8 → u16.
;   Inputs:  zp_br_a, zp_br_b (u8 each)
;   Output:  zp_br_res_l/resh (u16)
;   Uses:    umul8, the shared quarter-square multiplier
;            (a*b = f(a+b) - f(a-b), f(x) = x^2/4 table lookup);
;            clobbers zp_mul_b, zp_prod_l/hi, zp_tmp0, X, Y.
; Thin adapter from the br_a/br_b register convention onto umul8.
; ============================================================================
SEG_CODE
umul8_zp:
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
; (recip_hi moved to clip/rotvar.s 2026-08-09 — see above.)
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

; ============================================================================
; HELPER: frac_rot_term — fractional rotation contribution.
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
; view_setup (view.s) to build frac_vx/frac_vy — the rotation of the
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

frac_rot_term:
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
   ZERO zp_br_res_l, zp_br_res_h           ; (callers reload from res)
   RTS
.endscope


; (rot_core_sin/_cos/_cosv_nz + rot_gen_pair + every hi-partial arm and
;  sign tail DELETED 2026-08-11: rot_w_pages (view.s) is THE rotate —
;  unsigned page-decomposed operands, frame-constant combine signs.)

; (rot_pair_thunk moved to clip/rotvar.s 2026-08-09)
SEG_CODE
