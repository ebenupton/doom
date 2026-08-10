; ============================================================================
; clip/rotvar.s — the ex-LCODE island code (2026-08-09: ONE contiguous
; code area rule — the $1E00 island died; $1E00 is DATA-only now).
; Lives in the span_clip object so the bytes land in the inter-object
; alignment pad before bsp_render's fragment: zero net CODE growth.
; Contents: br_recip_hi (senior recip ladder) + the SMC-selected rotate
; variant entries + rot_pair_thunk. All JSR/SMC-called from the bsp
; object (linker-resolved imports/exports, per the no-jump-tables rule).
; ============================================================================
SEG_CODE
.export br_recip_hi
.export rot_zero, rot_unity_pos, rot_unity_neg
.export rot_zero_s, rot_unity_pos_s, rot_unity_neg_s
.export rot_gen_sin, rot_gen_cos, rot_pair_thunk, rpt_jsr, rpt_jmp
.import rot_core_sin, rot_core_cos          ; bsp/arith.s general cores
.import rns_vec_l, rns_go_op                ; project.s vectored shifter
.import RECIP_M8                            ; bsp/header.s equate (L2/flat)
                                            ; (rns_go_op = the NAMED SMC
                                            ; patch point, exported there)


; (br_recip junior entry DELETED 2026-08-09 — dead since the nc_ok
; inline; the senior ladder below is the only remaining entry.)
.scope
::br_recip_hi:                             ; caller-split entry (2026-07-27):
rcp_pnz:                                    ; A = idx hi (>= 1), Y = idx lo —
   CMP #4                                  ; the junior arm is inlined at
                                           ; nc_ok (seg_xform)
   BCS rcp_clamp                           ; idx >= 1024 -> clamp to 1023
   LSR A
   BEQ rcp_p1                              ; t1 = 1
   BCS rcp_p3                              ; t1 = 3
; t1 = 2: S = 10 except idx == 512 (Y == 0) -> 9
   LDA RECIP_M8+$200,Y
   STA zp_br_r_m8
   LDA #10
   CPY #0
   BNE rcp_s
   LDA #9
rcp_s:
   STA zp_br_r_s
; (RNS_SELECT expansion — the macro lives in bsp/header.s, not this
; unit; A = S per its contract, X dies, A becomes the vector byte)
   TAX
   LDA rns_vec_l-1,X
   STA rns_go_op
   RTS
rcp_clamp:
   LDY #$FF                                ; idx := 1023 (t1 -> page 3)
rcp_p3:
; t1 = 3: S = 10 always
   LDA RECIP_M8+$300,Y
   STA zp_br_r_m8
   LDA #10
   BNE rcp_s                               ; (A = 10: always)
rcp_p1:
; t1 = 1: S = 9 except idx == 256 (Y == 0) -> 8
   LDA RECIP_M8+$100,Y
   STA zp_br_r_m8
   LDA #9
   CPY #0
   BNE rcp_s
   LDA #8
   BNE rcp_s                               ; (A = 8: always)

.endscope                                   ; (the recip scope — its close
                                            ; sat after the srecip data in
                                            ; the old layout)

; --- variant entries: SMC-called ---
rot_zero:
   LDA #0
   STA zp_br_res_l
   STA zp_br_res_h
   RTS

; unity variants, SIGN-EXTERNAL (2026-07-19): ri_d arrives as |d| with
; the d-sign banked in zp_ri_sgn by the caller's operand staging — the
; product sign is trig-neg XOR d-neg, so pos and neg share two arms.
; COUNT-NATIVE (2026-08-10): unity = 32 counts/unit, so the product is
; |d| << 5 (s16): res_l = (d_l << 5) & FF, res_h = (d_l >> 3) ORA
; (d_h << 5) — the bit fields are disjoint (d_l>>3 <= 31; d_h <= 2 by
; the range asserts -> $20/$40).
rot_unity_pos:
   LDA zp_ri_sgn
   BNE ru_neg
ru_pass:
   LDX zp_ri_d_h
   LDA zp_ri_d_l
   LSR A
   LSR A
   LSR A                                   ; d_l >> 3
   CPX #0
   BEQ rup_h
   CPX #2
   BCS rup_h2
   ORA #$20                                ; d_h = 1
   BNE rup_h                               ; (A >= $20: always)
rup_h2:
   ORA #$40                                ; d_h = 2 (|d| = 512 exactly)
rup_h:
   STA zp_br_res_h
   LDA zp_ri_d_l
   ASL A
   ASL A
   ASL A
   ASL A
   ASL A                                   ; (d_l << 5) & FF
   STA zp_br_res_l
   RTS
rot_unity_neg:
   LDA zp_ri_sgn
   BNE ru_pass
ru_neg:
   JSR ru_pass                             ; positive form, then negate
   LDA #0                                  ; (rare-ish arm: axis-aligned
   SEC                                     ; trig frames only)
   SBC zp_br_res_l
   STA zp_br_res_l
   LDA #0
   SBC zp_br_res_h
   STA zp_br_res_h
   RTS

; --- sin-side twins (res-slot split 2026-07-19): the sin slot of a
; frame can hold unity/zero too, and those shared bodies can't serve
; two dests — so the sin side gets its own copies writing zp_rs_*.
; rot_select's sin arm picks these; the cos arm keeps the originals.
rot_zero_s:
   LDA #0
   STA zp_rs_l
   STA zp_rs_h
   RTS
rot_unity_pos_s:
   LDA zp_ri_sgn
   BNE rus_neg
rus_pass:
   LDX zp_ri_d_h
   LDA zp_ri_d_l
   LSR A
   LSR A
   LSR A
   CPX #0
   BEQ rusp_h
   CPX #2
   BCS rusp_h2
   ORA #$20
   BNE rusp_h
rusp_h2:
   ORA #$40
rusp_h:
   STA zp_rs_h
   LDA zp_ri_d_l
   ASL A
   ASL A
   ASL A
   ASL A
   ASL A
   STA zp_rs_l
   RTS
rot_unity_neg_s:
   LDA zp_ri_sgn
   BNE rus_pass
rus_neg:
   JSR rus_pass                            ; (mirror of ru_neg's form)
   LDA #0
   SEC
   SBC zp_rs_l
   STA zp_rs_l
   LDA #0
   SBC zp_rs_h
   STA zp_rs_h
   RTS

rot_gen_sin:
   LDA #0                                  ; SMC +1: |sin| mag (rot_select)
   STA zp_mul_b
   LDA #0                                  ; SMC +5: sin neg flag
   EOR zp_ri_sgn                           ; XOR the operand's banked sign
   STA zp_br_t1                            ; (the cores' in-place abs died)
   JMP rot_core_sin

rot_gen_cos:
   LDA #0                                  ; SMC +1: |cos| mag (rot_select)
   STA zp_mul_b
   LDA #0                                  ; SMC +5: cos neg flag
   EOR zp_ri_sgn
   STA zp_br_t1
   JMP rot_core_cos
rot_pair_thunk:
; non-gen frames: run the two selected variants in sequence, then ADAPT
; the cos result into vy (the variants keep their generic res dests;
; the pair contract is rs + vy since the direct-write, 2026-07-27 —
; this copy runs only on axis-aligned-trig frames, rare).
rpt_jsr:
   JSR rot_gen_sin                         ; +1/+2 SMC: the frame's sinvar
rpt_jmp:
   JSR rot_gen_cos                         ; +1/+2 SMC: the frame's cosvar
   LDA zp_br_res_l
   STA zp_br_vy_l
   LDA zp_br_res_h
   STA zp_br_vy_h
   RTS
