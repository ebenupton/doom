
; ============================================================================
; br_project_x_subpx — project view-space X to screen X with sub-pixel.
;
;   Inputs (zp):
;     zp_br_t0 = vx (s8, truncated view-space x)
;     zp_br_t1 = vx_frac (u8, fractional part)
;     zp_br_rhi = M8 (recip mantissa), zp_br_rlo = S (recip shift)
;
;   Output:
;     zp_br_resl/h = sx (s16 screen x)
;
;   Python (fp_project_x_subpx):
;     sx = 128 + rns(X88*m9, S+8)  with X88 = vx*256 + frac, m9 = 256+M8.
;
;   Two 8x8 multiplies (was 3 with the 8.8 recip — the third mul carried
;   recip bits below quarter-pixel significance). Exact identity used:
;     floor(X88*m9 / 256) = (frac*M8 >> 8) + frac
;                         + smul(vx, M8) + (vx << 8)
;   (only frac*M8 has bits below 2^8), accumulated as s24 in
;   (t2, t3, vxext) and handed to rns24 — bit-identical to Python's
;   rns(P32, S+8) by floor composition.
;
;   This is the NARROW path — the integer view-x must fit s8. Callers go
;   through br_project_x_auto (defq.s B region), which dispatches here or
;   to br_project_x_wide (lo.s, 3 muls) on the s16 view-x sign extension.
;   Clobbers zp_br_t2/t3, zp_br_vxext, zp_br_a/b, mul workspace.
; ============================================================================
br_project_x_subpx:
.scope
; --- b123 := (frac*M8 >> 8) + frac  (u9; both terms vanish when frac=0) ---
LDA #0
STA zp_br_t3
STA zp_br_vxext
; M8 == 0 (m9 = 256 exactly): both products are zero — b123 = frac + vx<<8.
LDA zp_br_rhi
BNE px_have_m8
LDA zp_br_t1
STA zp_br_t2
JMP px_p_pos
px_have_m8:
LDA zp_br_t1
BNE px_have_frac
STA zp_br_t2
BEQ px_no_frac
px_have_frac:
LDA zp_br_rhi
STA zp_mul_b
LDA zp_br_t1
JSR SC_UMUL8
LDA zp_prod_hi
CLC
ADC zp_br_t1
STA zp_br_t2
LDA #0
ADC #0
STA zp_br_t3
px_no_frac:

; --- += smul(vx, M8) (s16, sign-extended into vxext) ---
LDA zp_br_t0
STA zp_br_a
LDA zp_br_rhi
STA zp_br_b
JSR br_smul_s8_u8
LDA zp_br_resl
CLC
ADC zp_br_t2
STA zp_br_t2
LDA zp_br_resh
ADC zp_br_t3
STA zp_br_t3
BCC px_p_nc                             ; BCC/INC ext bump (carry ~50%)
INC zp_br_vxext
px_p_nc:
LDA zp_br_resh
BPL px_p_pos
DEC zp_br_vxext
px_p_pos:

; --- += vx << 8 (sign-extended) ---
LDA zp_br_t0
CLC
ADC zp_br_t3
STA zp_br_t3
BCC px_i_nc
INC zp_br_vxext
px_i_nc:
LDA zp_br_t0
BPL px_i_pos
DEC zp_br_vxext
px_i_pos:

; --- sx = 128 + rns(b123, S) (per-vertex vectored shifter) ---
JSR rns_go
LDA zp_br_resl
CLC
ADC #128
STA zp_br_resl
LDA zp_br_resh
ADC #0
STA zp_br_resh
RTS
.endscope

; ============================================================================
; br_project_y — project height delta to screen Y.
;
;   Inputs (zp):
;     zp_br_t0 = height_delta (s8)
;     zp_br_rhi = M8 (recip mantissa), zp_br_rlo = S (recip shift)
;
;   Output:
;     zp_br_resl/h = sy (s16)
;
;   Python (fp_project_y):
;     sy = HALF_H - rns(h*M8 + (h << 8), S)     [h*m9, m9 = 256+M8]
;
;   ONE signed s8×u8 multiply (was 2 with the 8.8 recip). The s24
;   product P = h*m9 (|P| <= 127*511, s17) goes through rns24 — the
;   shared round-to-nearest shifter, bit-identical to Python's rns.
;   With the near-plane crossing reciprocal (M8=0, S=1) this computes
;   sy = 128 - (h<<7) exactly: the mul degenerates to zero.
;
;   This label is br_project_y_RAW: the uncached projection body.
;   Production callers go through br_project_y (ycache.s), a memoising
;   front keyed on the full (M8, S, h) input tuple; only that front
;   calls _raw.
;
;   NOTE the constant loaded below is 128 = HALF_H (80) + Y_BIAS (48): the
;   screen-space Y bias every consumer used to add per-store is folded into
;   the projection, so results come out PRE-BIASED. Same final values.
;   Clobbers zp_br_t2/t3, zp_br_vxext, zp_br_a/b, mul workspace.
; ============================================================================
br_project_y_raw:
.scope
; --- P24 = h*M8 + (h << 8), s24 in (t2, t3, vxext) ---
; M8 == 0 (m9 = 256 exactly: the near-plane crossing recip and every
; power-of-two depth): the product is zero — skip the mul, P24 = h<<8.
LDA zp_br_rhi
BNE py_have_m8
STA zp_br_t2
LDA zp_br_t0
STA zp_br_t3
LDA #0
STA zp_br_vxext
LDA zp_br_t0
BPL py_go
DEC zp_br_vxext
py_go:
JMP py_shift
py_have_m8:
LDA zp_br_t0
STA zp_br_a
LDA zp_br_rhi
STA zp_br_b
JSR br_smul_s8_u8
LDA zp_br_resl
STA zp_br_t2
CLC
LDA zp_br_resh
ADC zp_br_t0                            ; mid = hi(h*M8) + h
STA zp_br_t3
LDA #0
ADC #0                                  ; carry from the mid add
STA zp_br_vxext
LDA zp_br_resh
BPL py_p_pos
DEC zp_br_vxext                         ; + sign extension of h*M8
py_p_pos:
LDA zp_br_t0
BPL py_h_pos
DEC zp_br_vxext                         ; + sign extension of h<<8
py_h_pos:
py_shift:

; --- sy = 128 - rns(P24, S) (per-vertex vectored shifter) ---
JSR rns_go
LDA #128
SEC
SBC zp_br_resl
STA zp_br_resl
LDA #0
SBC zp_br_resh
STA zp_br_resh
RTS
.endscope

; ============================================================================
; RNS VECTORING — the shift S is a per-vertex constant, so the shifter is
; selected ONCE per reciprocal (rns_select, called from every zp_br_rlo
; writer: br_recip, the vcache hit path, ap2_solid_proj) and projections
; jump straight to the right unrolled body through zp_rns_vec — no
; per-projection dispatch, no loop. Bodies: rns_s6/s7/s10 here (MAIN space
; freed by evicting the verticals block to CEMIT — the debug HUD's bank C
; window), rns_s8/s9 in resolve_crossing.s, generic rns24 (ANG) for the
; rare S in [1,5]. All bodies are bit-exact floor((P + 2^(S-1)) / 2^S).
; The whole vectoring block lives in the STK region — the bottom of the
; hardware stack page ($0100-$01BF, resident in every build; measured SP
; floor is $F1 so the stack never comes near). Pure leaf routines: no
; JSRs inside, so they add nothing to the stack depth they live under.
; ============================================================================
.segment "STK"
rns_go:
JMP (zp_rns_vec)

rns_select:
.scope
LDX zp_br_rlo
LDA rns_vec_lo-1,X
STA zp_rns_vec
LDA rns_vec_hi-1,X
STA zp_rns_vec_hi
RTS
.endscope
rns_vec_lo:
.byte <rns24, <rns24, <rns24, <rns24, <rns24
.byte <rns_s6, <rns_s7, <rns_s8, <rns_s9, <rns_s10
rns_vec_hi:
.byte >rns24, >rns24, >rns24, >rns24, >rns24
.byte >rns_s6, >rns_s7, >rns_s8, >rns_s9, >rns_s10

rns_s8:
.scope
; floor((P + $80) / 256): carry out of the b0 half-add, then drop b0
LDA zp_br_t2
CLC
ADC #$80
LDA zp_br_t3
ADC #0
STA zp_br_resl
LDA zp_br_vxext
ADC #0
STA zp_br_resh
RTS
.endscope
rns_s9:
.scope
; floor((P + $100) / 512): t3 += 1 (carry into ext), ASR the top pair
LDA zp_br_t3
CLC
ADC #1
TAX
LDA zp_br_vxext
ADC #0
CMP #$80                                ; C = sign bit → arithmetic ROR
ROR A
STA zp_br_resh
TXA
ROR A
STA zp_br_resl
RTS
.endscope

rns_s6:
.scope
; floor((P + $20) / 64) = ((P + $20) << 2) >> 8
LDA zp_br_t2
CLC
ADC #$20
STA zp_br_t2
LDA zp_br_t3
ADC #0
STA zp_br_t3
LDA zp_br_vxext
ADC #0
STA zp_br_vxext
ASL zp_br_t2
ROL zp_br_t3
ROL zp_br_vxext
ASL zp_br_t2
LDA zp_br_t3
ROL A
STA zp_br_resl
LDA zp_br_vxext
ROL A
STA zp_br_resh
RTS
.endscope

rns_s7:
.scope
; floor((P + $40) / 128) = ((P + $40) << 1) >> 8
LDA zp_br_t2
CLC
ADC #$40
STA zp_br_t2
LDA zp_br_t3
ADC #0
STA zp_br_t3
LDA zp_br_vxext
ADC #0
STA zp_br_vxext
ASL zp_br_t2
LDA zp_br_t3
ROL A
STA zp_br_resl
LDA zp_br_vxext
ROL A
STA zp_br_resh
RTS
.endscope

rns_s10:
.scope
; floor((P + $200) / 1024): t3 += 2 (carry into ext), drop b0, ASR twice
LDA zp_br_t3
CLC
ADC #2
STA zp_br_t3
LDA zp_br_vxext
ADC #0
CMP #$80                                ; C = sign → arithmetic ROR
ROR A
ROR zp_br_t3
CMP #$80
ROR A
ROR zp_br_t3
STA zp_br_resh
LDA zp_br_t3
STA zp_br_resl
RTS
.endscope
.segment "MAIN"

; (rns24 generic + the rns_half tables live in the D region —
; resolve_crossing.s — and LO; MAIN is at its $5800 ceiling.)


.if ::BANKED
.segment "ANG_BK"
.else
.segment "ANG"
.endif
; ============================================================================
rns24:
.scope
LDX zp_br_rlo
; --- add half = 2^(S-1): lo byte for S<=8, mid byte holds S=9,10 ---
LDA rns_half_lo-1,X
CLC
ADC zp_br_t2
STA zp_br_t2
LDA rns_half_mid-1,X
ADC zp_br_t3
STA zp_br_t3
BCC rn_half_nc                          ; BCC/INC ext bump (-2 bytes, ANG is full)
INC zp_br_vxext
rn_half_nc:
CPX #8
BCC rn_small
; --- S >= 8 here means S = 10: rns_fast (the only caller) intercepts
; S = 8 and S = 9 with unrolled bodies. Drop b0, ASR twice. ---
LDA zp_br_vxext
CMP #$80                                ; C = sign bit → arithmetic ROR
ROR zp_br_vxext
ROR zp_br_t3
LDA zp_br_vxext
CMP #$80
ROR zp_br_vxext
ROR zp_br_t3
rn_tail_mid:
LDA zp_br_t3
STA zp_br_resl
LDA zp_br_vxext
STA zp_br_resh
RTS
rn_small:
CPX #5
BCC rn_right
; --- S in [5,7]: shift LEFT (8-S) — 1..3 iterations — then drop b0 ---
LDA #8
SEC
SBC zp_br_rlo
TAX                                     ; X = 8-S in [1,3]
rn_lloop:
ASL zp_br_t2
ROL zp_br_t3
ROL zp_br_vxext
DEX
BNE rn_lloop
BEQ rn_tail_mid                         ; (always) result = (t3, vxext)
rn_right:
; --- S in [1,4]: ASR the s24 S times — 1..4 iterations. S=1 is the
; near-plane crossing reciprocal, so this path is hot for clipped segs.
rn_rloop:
LDA zp_br_vxext
CMP #$80
ROR zp_br_vxext
ROR zp_br_t3
ROR zp_br_t2
DEX
BNE rn_rloop
LDA zp_br_t2
STA zp_br_resl
LDA zp_br_t3
STA zp_br_resh
RTS
.endscope


.if ::BANKED
.segment "MAIN"
.else
.segment "MAIN"
.endif

; ============================================================================
; ROM/RAM base addresses (Python wrapper writes these into ZP at frame start)
; "zp_"-named for history but these live in the $0BEC-$0BF7 absolute page —
; cold, read a few times per seg via indirect-pointer setup. They point at
; the packed WAD arrays built by wad_packed.build_packed (vertices,
; subsector SoA pages, seg headers, VWH heights, seg detail).
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
