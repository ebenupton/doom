
; ============================================================================
; clip/dcl_s16.s — clipper fragment 10 of 10, last in the link (module
; map: clip/header.s). Contents: the wide-arithmetic primitives
; (umul16x16, udiv32_16, s16_interp) and the s16 pre-clip entries
; draw_clipped_line_s16 / draw_clipped_line_s16_h, which clip to the u8 box and dispatch into
; draw_clipped_line (clip/dcl.s). LC_* working-set addresses are
; declared in clip/tfr.s; s16_interp is also reused by dcl_yband_clip
; (clip/dcl.s) with swapped axes.
; ============================================================================

; (umul16x16 inlined+specialised into si_general 2026-07-16 —
; single caller; operands read straight from LC_OFF/LC_DY, the
; LC_M_A/B staging slots are dead.)


; (udiv32_16 inlined into si_general 2026-07-16 — single caller.)


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
;
; Python mirror: _interp_store_s16 (endpoint_spans.py).  Computes with
; |offset|, |den|, |dy| and a +den//2 bias before the divide, then
; adds/subtracts the quotient — i.e. rounds half AWAY FROM ZERO (see
; the mirror's docstring for the 1px descending-line bug this fixed).
; Pseudocode:
;   off = tgt - x0; den = x1 - x0
;   if den < 0: off, den = -off, -den
;   if den == 0 or off == 0: return y0     # degenerate / at anchor 1
;   if off == den: return y1               # at anchor 2
;   dy = y1 - y0; if dy == 0: return y0    # horizontal
;   q = (|off| * |dy| + den//2) // den     # u8 fast path: umul8 +
;                                          # udiv16_8; else 16x16/32:16
;   res = y0 + q if dy > 0 else y0 - q
;   A = clamp(res, 0, 255); LC_RES = res
; NOTE: no directed rounding here — callers that need floor/ceil
; behaviour (dcl_boundary_ix) do their own arithmetic.
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
; If den < 0, negate both offset and den. (A and N are the SBC's — no
; reload needed for the sign test.)
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
   ADC zp_prod_l
   STA zp_div_l
   LDA #0
   ADC zp_prod_h
   STA zp_div_h
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
; multiply: |offset| × |dy| → u32, INLINE (was umul16x16 — single
; caller): operands read straight from LC_OFF/LC_DY, no staging; the
; a_hi=0/b_hi=0 fast paths survive.
.scope

; Always need p1 = a_lo * b_lo.
   LDA LC_DY_LO
   STA zp_mul_b
   LDA LC_OFF_LO
   JSR umul8
   STA LC_M_R1                             ; A = prod_hi (umul8 contract)
   LDA zp_prod_l
   STA LC_M_R0
   LDA #0
   STA LC_M_R2
   STA LC_M_R3

; Fast paths: skip multiplies whose factor is zero.
   LDA LC_DY_HI
   BEQ skip_p2

   STA zp_mul_b                            ; A = b_hi from the test above
   LDA LC_OFF_LO
   JSR umul8
; p2 = a_lo * b_hi
   LDA zp_prod_l
   CLC
   ADC LC_M_R1
   STA LC_M_R1
   LDA zp_prod_h
   ADC LC_M_R2
   STA LC_M_R2
   LDA #0
   ADC LC_M_R3
   STA LC_M_R3
skip_p2:

   LDA LC_OFF_HI
   BEQ skip_p3_p4

   LDA LC_DY_LO
   STA zp_mul_b
   LDA LC_OFF_HI
   JSR umul8
; p3 = a_hi * b_lo
   LDA zp_prod_l
   CLC
   ADC LC_M_R1
   STA LC_M_R1
   LDA zp_prod_h
   ADC LC_M_R2
   STA LC_M_R2
   LDA #0
   ADC LC_M_R3
   STA LC_M_R3

   LDA LC_DY_HI
   BEQ skip_p3_p4
; if b fits u8, p4 = a_hi * 0 = 0
   STA zp_mul_b                            ; A = b_hi from the test above
   LDA LC_OFF_HI
   JSR umul8
; p4 = a_hi * b_hi
   LDA zp_prod_l
   CLC
   ADC LC_M_R2
   STA LC_M_R2
   LDA zp_prod_h
   ADC LC_M_R3
   STA LC_M_R3
skip_p3_p4:
.endscope
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
   BCC m_r_nc                              ; BCC/INC 2-byte propagate:
   INC LC_M_R2                             ; wrap of R2 carries into R3
   BNE m_r_nc
   INC LC_M_R3
m_r_nc:
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
   BCC u16_quot_noreload
   BNE no_u16_quot
   LDA LC_M_R2
   CMP LC_DEN_LO
   BCS no_u16_quot
u16_quot:
   LDA LC_M_R3                             ; (lo-tier fall only: the hi BCC
u16_quot_noreload:                         ; arrives with R3 live)
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
   BCC u16_set                             ; no-sub: C=0 rides into the ROL
   STA LC_REM_HI
   LDA LC_TMP_LO
   STA LC_REM_LO                           ; sub taken: C=1 from the SBC
u16_set:
   ROL LC_QUOT_LO
   ROL LC_QUOT_HI
   DEX
   BNE u16_loop
   JMP udv_done

no_u16_quot:
; ---- Slow path: u32 ÷ u16 → up to u17 quotient ----
; (Rare for s16 clipper; kept for correctness.) Use byte-level skip
; + bit-level skip to trim no-op iterations.
   LDA #0
   STA LC_REM_LO
   STA LC_REM_HI
; Byte-level skip: while the top dividend byte (R3) is zero, shift the
; dividend left 8 bits in one move (R2->R3, R1->R2, R0->R1, 0->R0) and
; drop the iteration count by 8.  X = 32/24/16/8 iterations remaining.
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
   JMP udv_done                                     ; dividend == 0 → quot = rem = 0
bit_skip:
; Bit-level skip: shift left until the dividend MSB is set (those
; iterations can never make rem >= den since rem stays 0).
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
udv_done:
.endscope
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
; (no load: ALL six inbound paths — add/sub, u8 fast pair, return_y0/
; y1 — end STA LC_RES_HI, so A converges holding it; regscan 2026-07-19)
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
; Reads zp_line_xl_l..zp_line_yr_h (8 bytes of s16 input).
; Writes u8 to zp_line_xl_l, zp_line_yl_l, zp_line_xr_l, zp_line_yr_l and
; falls through to draw_clipped_line. If line fully off-screen,
; degenerate, or otherwise rejected, RTS without invoking DCL.
;
; Python mirror: the wrapper side of span_clip_6502.draw_clipped_line
; plus _clip_to_screen semantics.  The CALLER has already ordered the
; endpoints left-to-right (x1 <= x2), rejected zero-length input, and
; written the LO bytes — which alias zp_line_xl_l/yl/xr/yr — so the
; all-in-u8 fast path is a single 4-byte OR test and a JMP.
;
; Pseudocode (slow path):
;   if HI(x1)|HI(y1)|HI(x2)|HI(y2) == 0: goto draw_clipped_line
;   if both x < 0 or both x > 255: reject     # same-side quick reject
;   if both y < 0 or both y > 255: reject
;   if either x out of [0,255]:               # X clip (per endpoint)
;       y_at = s16_interp(x = 0 or 255)       # UNCLAMPED s16 result —
;       (x, y) = (edge, y_at)                 # y may still be out of
;                                             # range for the y-clip
;   if both y < 0 or both y > 255: reject     # re-check after x-clip
;   if either y out of [0,255]:               # Y clip, axes swapped
;       x_at = s16_interp(y = 0 or 255)       # (clamped u8 is fine:
;       (x, y) = (x_at, edge)                 #  x already in [0,255])
;   if xl > xr: swap endpoints                # clip can reorder (rare)
;   if xl == xr and yl == yr: reject          # clipped to a point
;   goto draw_clipped_line
; --- draw_clipped_line_s16_h: horizontal-emit entry -------------------
; In: X = offset of the s16 y coord inside EACH vertex struct (the four
;     sy pairs sit at the same offsets in VX1 and VX2, so one offset
;     names the line: +5 top, +7 bot, +9 btop, +11 bbot; lo at VX+X,
;     hi at VX+X+1). The x pair comes straight from zp_seg_sx1/sx2.
; THE SEG LAYER OWNS THE LEFT-TO-RIGHT CONTRACT: the seg loop
; CANONICALIZES on the rare 1px edge-on reversal (seg_swap_vx exchanges
; the endpoint structs post-visibility), so VX1 is ALWAYS the left
; endpoint here — no ord dispatch, no mirrored staging, and the
; clipper's per-draw swap machinery stays GONE (see main_clip).
; All four hi bytes are tested BEFORE any staging: the common all-in-u8
; case stages just the four lo bytes the u8 DCL reads (the hi slots
; overlay the u8 DCL's zp_cb_* workspace, written before every read).
draw_clipped_line_s16_h:
   LDA VX1+1,X                             ; y1 hi
   ORA VX2+1,X                             ; y2 hi
   ORA zp_seg_sx1_h
   ORA zp_seg_sx2_h
   BNE dclh_slow
   LDA zp_seg_sx1_l
   STA zp_line_xl_l
   LDA zp_seg_sx2_l
   STA zp_line_xr_l
   LDA VX1,X
   STA zp_line_yl_l
   LDA VX2,X
   STA zp_line_yr_l
   JMP dcl16_fastu8
dclh_slow:
; some coord outside u8: stage the full s16 line for the classic clip
   LDA zp_seg_sx1_l
   STA zp_line_xl_l
   LDA zp_seg_sx1_h
   STA zp_line_xl_h
   LDA zp_seg_sx2_l
   STA zp_line_xr_l
   LDA zp_seg_sx2_h
   STA zp_line_xr_h
   LDA VX1,X
   STA zp_line_yl_l
   LDA VX1+1,X
   STA zp_line_yl_h
   LDA VX2,X
   STA zp_line_yr_l
   LDA VX2+1,X
   STA zp_line_yr_h
   JMP dcl16_mainclip

draw_clipped_line_s16:
.scope
; ---- Order endpoints / reject the degenerate point ----
; This entry OWNS the ordering contract (swap when x1 > x2, reject the
; zero-length point), mirroring the harness wrapper's Python prelude.
; It used to be caller-side only: the harness wrapper did it, but the
; NATIVE seg emitters (bsp/subsector.s) stage sx1/sx2 raw — and a
; nearly-edge-on seg can project REVERSED by one pixel (sub-pixel
; rounding inverts the 1px order). A reversed line walked the span
; list without emitting or recording, the portal's tighten record was
; lost, and the aperture stayed open — far subtrees leaked through
; (the 8F.1F/0F.DB/84 "solid bars": 1891px over-draw, 4x frame cost).
; Records counts need no handling on the reject path: the seg emitter
; pre-zeroes TOP/BOT_RECORDS counts (and the wrapper zeroes its buffer)
; before any edge is staged.
;
; ---- Fast path: all 4 endpoints already in u8 range ----
; HI bytes all zero ⇔ all coords in [0, 255]; u8 compares suffice for
; the ordering contract here.  zp_line_xl_l/yl/xr/yr (shared with the u8 path via
; alias) are already written by the caller.
   LDA zp_line_xl_h
   ORA zp_line_yl_h
   ORA zp_line_xr_h
   ORA zp_line_yr_h
   BNE main_clip
::dcl16_fastu8:
; input contract: xl <= xr (seg layer / wrapper ordered) — equality is
; the only case left to classify (vertical vs zero-length point)
   LDA zp_line_xl_l
   CMP zp_line_xr_l
   BEQ fp_x_eq
   JMP draw_clipped_line
fp_x_eq:
; x1 == x2: vertical unless y1 == y2 (zero-length point → reject)
   LDA zp_line_yl_l
   CMP zp_line_yr_l
   BEQ fp_degen
   JMP draw_clipped_line
fp_degen:
   RTS

main_clip:
::dcl16_mainclip:
; no pending right-side band verdict yet ($80 = none)
   LDA #$80
   STA DCLV_S16VY
; ---- Slow path. INPUT CONTRACT: x1 <= x2 as s16 — ordering is owned
; by the CALLERS now (the seg layer stages via zp_sx_ord, the Python
; wrapper orders in its prelude, verticals are trivially ordered).
; The old in-clipper swap existed for the 8F.1F 1px edge-on reversal;
; that case now arrives pre-mirrored from draw_clipped_line_s16_h.
; Only the zero-length reject remains ----
   LDA zp_line_xl_l
   CMP zp_line_xr_l
   BNE mc_ordered
   LDA zp_line_xl_h
   CMP zp_line_xr_h
   BNE mc_ordered_noreload
; x1 == x2 (s16): degenerate iff y1 == y2 too, else a VERTICAL — the
; clamp fast path below (the generic path staged anchors and ran
; s16_interp twice just to hand back x unchanged)
   LDA zp_line_yl_l
   CMP zp_line_yr_l
   BNE mc_vertical
   LDA zp_line_yl_h
   CMP zp_line_yr_h
   BNE mc_vertical
   RTS                                     ; zero-length point → reject

mc_vertical:
; Vertical clamp (2026-07-15). Clipping a vertical to the u8 box is a
; y-clamp: the x at any y-boundary IS x (s16_interp's dy==0 early-out
; returned exactly that, ~700 cycles later). Bit-exact vs the generic
; path by construction; the engine's vertical emitters are the only
; live callers of this entry and always arrive disarmed. ARMED lines
; (harness wrapper only) keep the generic path — its y-census emits
; flat verdict records this fast path doesn't model.
   LDA zp_dcl_rec_buf_h
   BNE mc_ordered
; x1 == x2, so off-screen x is same-side by definition: reject unless
; x in [0,255] (hi == 0)
   LDA zp_line_xl_h
   BNE mcv_rej
; clamp y1 (s16: in-band iff hi == 0; hi < 0 → above; hi > 0 → below),
; rejecting the same-side-out pairs the generic quick-reject catches
   LDA zp_line_yl_h
   BEQ mcv_y1_done                         ; y1 in band
   BMI mcv_y1_neg
   LDA zp_line_yr_h                        ; y1 below: y2 also below → out
   BMI mcv_y1_cl
   BNE mcv_rej
mcv_y1_cl:
   LDA #$FF
   STA zp_line_yl_l
   LDA #0
   STA zp_line_yl_h
   BEQ mcv_y1_done                         ; always
mcv_y1_neg:
   LDA zp_line_yr_h                        ; y1 above: y2 also above → out
   BMI mcv_rej
   LDA #0
   STA zp_line_yl_l
   STA zp_line_yl_h
mcv_y1_done:
; clamp y2
   LDA zp_line_yr_h
   BEQ mcv_y2_done
   BMI mcv_y2_neg
   LDA #$FF
   STA zp_line_yr_l
   LDA #0
   STA zp_line_yr_h
   BEQ mcv_y2_done                         ; always
mcv_y2_neg:
   LDA #0
   STA zp_line_yr_l
   STA zp_line_yr_h
mcv_y2_done:
; clamped to a point (one end was AT the boundary) → reject, exactly
; as the generic post-clip degen check does
   LDA zp_line_yl_l
   CMP zp_line_yr_l
   BEQ mcv_rej
; all-u8 vertical; disarmed, so no flush is owed (DCLV_S16VY holds the
; $80 written at entry — same state the fast-u8 path leaves)
   JMP draw_clipped_line
mcv_rej:
   RTS

mc_ordered:
; ---- Quick reject: both endpoints on the same side of any edge ----
; Both x < 0?  hi byte negative for both means both < 0 (s16).
   LDA zp_line_xl_h                        ; (lo-differ path reloads; the
mc_ordered_noreload:                       ; hi-differ BNE has xl_h live)
   BPL x1_in_or_big
   LDA zp_line_xr_h
   BPL not_both_xneg
   JMP rejected
x1_in_or_big:
; zp_line_xl_h ≥ 0. Check if zp_line_xl_l/HI > 255 (i.e. HI != 0).
   BEQ not_both_xbig                       ; HI = 0 → in [0, 255] (low byte)
; HI > 0 → x1 > 255. Is x2 also > 255?
   LDA zp_line_xr_h
   BMI not_both_xbig
; x2 < 0 → not both > 255
   BEQ not_both_xbig                       ; x2 in [0, 255] → not both > 255
; both > 255
   JMP rejected
not_both_xneg:
not_both_xbig:
; same for y — RECORDS-OFF ONLY: with records on, a both-out line falls
; through so the post-x-clip census emits its flat verdict record with
; u8 x values (aperture fix part 2); records-off keeps the cheap reject.
   LDA zp_line_yl_h
   BPL y1_in_or_big
   LDA zp_line_yr_h
   BPL not_both_yneg
   LDA zp_dcl_rec_buf_h
   BNE not_both_yneg
   JMP rejected
y1_in_or_big:
   BEQ not_both_ybig
   LDA zp_line_yr_h
   BMI not_both_ybig
   BEQ not_both_ybig
   LDA zp_dcl_rec_buf_h
   BNE not_both_ybig
   JMP rejected
not_both_yneg:
not_both_ybig:

; ---- Skip x-clip path entirely if both x already in u8 ----
; (We got here because at least one HI byte is non-zero; might be y.)
   LDA zp_line_xl_h
   ORA zp_line_xr_h
   BNE need_xclip
   JMP skip_xclip
need_xclip:

; ---- Save originals for x-clip interp (only when needed) ----
   LDA zp_line_xl_l
   STA LC_OX1_LO
   LDA zp_line_xl_h
   STA LC_OX1_HI
   LDA zp_line_yl_l
   STA LC_OY1_LO
   LDA zp_line_yl_h
   STA LC_OY1_HI
   LDA zp_line_xr_l
   STA LC_OX2_LO
   LDA zp_line_xr_h
   STA LC_OX2_HI
   LDA zp_line_yr_l
   STA LC_OY2_LO
   LDA zp_line_yr_h
   STA LC_OY2_HI

; ---- X clip ----
; If x1 < 0, replace y1 with y at x=0; x1 = 0.
; Else if x1 > 255, replace y1 with y at x=255; x1 = 255.
   LDA zp_line_xl_h
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
   STA zp_line_yl_l
   LDA LC_RES_HI
   STA zp_line_yl_h
   LDA #0
   STA zp_line_xl_l
   STA zp_line_xl_h
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
   STA zp_line_yl_l
   LDA LC_RES_HI
   STA zp_line_yl_h
   LDA #$FF
   STA zp_line_xl_l
   LDA #0
   STA zp_line_xl_h
x1_done:
; same for x2
   LDA zp_line_xr_h
   BPL x2_not_neg
   LDA #0
   STA LC_TGT_LO
   STA LC_TGT_HI
   JSR s16_interp
; store UNCLAMPED crossing Y (see zp_line_yl_l note above).
   LDA LC_RES_LO
   STA zp_line_yr_l
   LDA LC_RES_HI
   STA zp_line_yr_h
   LDA #0
   STA zp_line_xr_l
   STA zp_line_xr_h
   JMP x2_done
x2_not_neg:
   BEQ x2_done
   LDA #$FF
   STA LC_TGT_LO
   LDA #0
   STA LC_TGT_HI
   JSR s16_interp
; store UNCLAMPED crossing Y (see zp_line_yl_l note above).
   LDA LC_RES_LO
   STA zp_line_yr_l
   LDA LC_RES_HI
   STA zp_line_yr_h
   LDA #$FF
   STA zp_line_xr_l
   LDA #0
   STA zp_line_xr_h
x2_done:
skip_xclip:

; ---- Quick reject after x-clip (y might still be out same side) ----
   LDA zp_line_yl_h
   BPL y1_after_in_or_big
   LDA zp_line_yr_h
   BPL not_both_yneg2
   LDA #0                                  ; whole line above the band
   JSR dcl_rec_flat_line
   JMP rejected
y1_after_in_or_big:
   BEQ not_both_ybig2
   LDA zp_line_yr_h
   BMI not_both_ybig2
   BEQ not_both_ybig2
   LDA #$FF                                ; whole line below the band
   JSR dcl_rec_flat_line
   JMP rejected
not_both_yneg2:
not_both_ybig2:

; ---- If both y already in u8, skip y-clip ----
   LDA zp_line_yl_h
   BNE need_yclip
   LDA zp_line_yr_h
   BNE need_yclip
   JMP y_in_range
need_yclip:
; Re-snap originals to post-x-clip values; for y-clip, axes swap:
; OX* now holds the FREE axis (y), OY* the TARGET (x).
   LDA zp_line_yl_l
   STA LC_OX1_LO
   LDA zp_line_yl_h
   STA LC_OX1_HI
   LDA zp_line_xl_l
   STA LC_OY1_LO
   LDA zp_line_xl_h
   STA LC_OY1_HI
   LDA zp_line_yr_l
   STA LC_OX2_LO
   LDA zp_line_yr_h
   STA LC_OX2_HI
   LDA zp_line_xr_l
   STA LC_OY2_LO
   LDA zp_line_xr_h
   STA LC_OY2_HI

; y1 clip
   LDA zp_line_yl_h
   BPL y1c_not_neg
   LDA #0
   STA LC_TGT_LO
   STA LC_TGT_HI
   JSR s16_interp
   STA zp_line_xl_l
   LDA #0
   STA zp_line_xl_h
   STA zp_line_yl_l                        ; A still 0
   STA zp_line_yl_h
   LDA zp_dcl_rec_buf_h
   BEQ y1c_done
   LDA #0                                  ; [orig xl, xl] exited via TOP
   JSR dcl_rec_flat_y1
   JMP y1c_done
y1c_not_neg:
   BEQ y1c_done
   LDA #$FF
   STA LC_TGT_LO
   LDA #0
   STA LC_TGT_HI
   JSR s16_interp
   STA zp_line_xl_l
   LDA #0
   STA zp_line_xl_h
   LDA #$FF
   STA zp_line_yl_l
   LDA #0
   STA zp_line_yl_h
   LDA zp_dcl_rec_buf_h
   BEQ y1c_done
   LDA #$FF                                ; [orig xl, xl] exited via BOTTOM
   JSR dcl_rec_flat_y1
y1c_done:
; y2 clip
   LDA zp_line_yr_h
   BPL y2c_not_neg
   LDA #0
   STA LC_TGT_LO
   STA LC_TGT_HI
   JSR s16_interp
   STA zp_line_xr_l
   LDA #0
   STA zp_line_xr_h
   STA zp_line_yr_l                        ; A still 0...
   STA zp_line_yr_h
   STA DCLV_S16VY                          ; [xr, orig xr] exited via TOP:
                                        ; pend 0 (order: after walk recs)
   JMP y2c_done
y2c_not_neg:
   BEQ y2c_done
   LDA #$FF
   STA LC_TGT_LO
   LDA #0
   STA LC_TGT_HI
   JSR s16_interp
   STA zp_line_xr_l
   LDA #0
   STA zp_line_xr_h
   LDA #$FF
   STA zp_line_yr_l
   LDA #0
   STA zp_line_yr_h
   LDA #$FF                                ; [xr, orig xr] exited via BOTTOM
   STA DCLV_S16VY
y2c_done:
y_in_range:

; ---- Order/copy/degen handled by wrapper for input; clipping in
; this slow path could shrink the line to a point, so check that
; one case before dispatching. zp_line_* already holds the clipped
; values (written in place by the clip steps above — the old LC_*_LO
; alias layer was removed 2026-07-10).
; NB the "bail" margin note on the BNE below is stale (2026-07-12):
; rejected_swap_after_clip SWAPS the endpoints and still emits — see
; its own comment.
   LDA zp_line_xl_l
   CMP zp_line_xr_l
   BCC dispatch_dcl
   BNE rsac_noreload                       ; clipping reordered: bail (rare)
   LDA zp_line_yl_l
   CMP zp_line_yr_l
   BEQ rejected
dispatch_dcl:
   JSR draw_clipped_line
   JMP dcl_rec_s16r_flush
rejected_swap_after_clip:
; Post-clip x1 > x2 — would require swap; just emit reordered.
   LDA zp_line_xl_l                        ; (xl_l live at the BNE site)
rsac_noreload:
   LDX zp_line_xr_l
   STX zp_line_xl_l
   STA zp_line_xr_l
   LDA zp_line_yl_l
   LDX zp_line_yr_l
   STX zp_line_yl_l
   STA zp_line_yr_l
   JSR draw_clipped_line
   JMP dcl_rec_s16r_flush
rejected:
   JMP dcl_rec_s16r_flush                  ; pending may be armed even when
                                        ; the in-band piece degenerated
.endscope

; ============================================================================
; Part 2 of the off-screen-aperture fix (2026-07-13): the s16 band clip
; emits FLAT VERDICT records (0 'above' / $FF 'below') for the y-band-
; clipped-away portions of an aperture edge, so the tighten keeps the
; memory that the edge exists out there. Wrappers live in LO (main RAM,
; always mapped); dcl_rec_flat gates on records mode and merges.
; ============================================================================
.segment "LOX"
dcl_rec_flat_line:                         ; whole clipped line [xl_l, xr_l]
   STA DCLV_YV
   LDA zp_line_xl_l
   STA DCLV_X0
   LDA zp_line_xr_l
   STA DCLV_X1
   LDA DCLV_YV
   JMP dcl_rec_flat

dcl_rec_flat_y1:                           ; left clip-off [orig xl, new xl]
   STA DCLV_YV
   LDA LC_OY1_LO
   STA DCLV_X0
   LDA zp_line_xl_l
   STA DCLV_X1
   LDA DCLV_YV
   JMP dcl_rec_flat

dcl_rec_s16r_flush:                        ; right clip-off [new xr, orig xr]
   LDA DCLV_S16VY
   CMP #$80
   BEQ s16r_done
   STA DCLV_YV
   LDA #$80
   STA DCLV_S16VY                          ; consume the pending
   LDA zp_line_xr_l
   STA DCLV_X0
   LDA LC_OY2_LO
   STA DCLV_X1
   LDA DCLV_YV
   JMP dcl_rec_flat
s16r_done:
   RTS
.if ::BANKED
.segment "CLIP_BK"
.else
.segment "CLIP"
.endif

end_code:
.if ::BANKED
; (output file: ld65 writes the CLIP_BK region ($8000) to
;  span_clip_bankc.bin — engine_banked.cfg MEMORY entry; the SAVE
;  directive of the old beebasm build is gone)
.else
; (output file: ld65 writes the CLIPJT+CLIP regions ($2000/$2030) to
;  span_clip.bin — engine_flat.cfg MEMORY entries)
.endif
