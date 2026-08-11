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

; (The rot variant entries + gen thunks + rot_pair_thunk DELETED
;  2026-08-11 — the legacy rot machinery died with rot_w_pages.)
