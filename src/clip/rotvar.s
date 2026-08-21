; ============================================================================
; clip/rotvar.s — clipper fragment 12 of 13 (module map: clip/header.s).
; The ex-LCODE island code (2026-08-09: ONE contiguous
; code area rule — the $1E00 island died; $1E00 is DATA-only now).
; Lives in the span_clip object so the bytes land in the inter-object
; alignment pad before bsp_render's fragment: zero net CODE growth.
; Contents: recip_hi (senior recip ladder) + the SMC-selected rotate
; variant entries + rot_pair_thunk. All JSR/SMC-called from the bsp
; object (linker-resolved imports/exports, per the no-jump-tables rule).
; ============================================================================
SEG_CODE
.export recip_hi
.import RECIP_M8, RECIP_M8H                 ; bsp/header.s equates (L2/flat)


; (br_recip junior entry DELETED 2026-08-09 — dead since the nc_ok
; inline; the senior ladder below is the only remaining entry.)
.scope
::recip_hi:                             ; caller-split entry:
rcp_pnz:                                    ; A = idx hi (>= 1), Y = idx lo
; FAR SYNTHESIS (2026-08-13, Eben's smaller-tables idea): reduce the
; index into the [128,255] half by 1-2 right shifts — the reciprocal's
; scaling identity keeps the mantissa domain and adds the shift count
; to S (EXACT: bit_length composes through the shifts; only M8 loses
; the shifted-out index bits — ~1-2 lsb of far distance resolution).
; The linear M8 pages 1-3 died for the 128-byte RECIP_M8H half-table.
; Mirrors fp.fp_recip. Clobbers A, X, Y.
   CMP #4
   BCC rcp_r
   LDA #3                                  ; idx >= 1024: clamp to 1023
   LDY #$FF
rcp_r:
   LSR A                                   ; C = hi bit 0; A = 0 (hi 1) /
   BNE rcp_two                             ;  1 (hi 2-3: two shifts)
   TYA                                     ; ONE shift: C = 1 (hi was 1),
   ROR A                                   ; idx2 = $80 | lo>>1
   TAY
   LDX #1                                  ; sh = 1
   BNE rcp_fetch                           ; (always)
rcp_two:
   TYA
   ROR A                                   ; (hi & 1) -> b7, lo >>= 1
   SEC
   ROR A                                   ; $80 | (hi&1)<<6 | lo>>2
   TAY
   LDX #2                                  ; sh = 2
rcp_fetch:
   LDA RECIP_M8H-128,Y                     ; far half-table (idx2 - 128)
   STA zp_br_r_m8
   CPY #$80
   BEQ rcp_pow                             ; idx2 = 128: an exact power —
   TXA                                     ;  S is one lower (bit_length)
   CLC
   ADC #8                                  ; S = sh + 8
   STA zp_br_r_s
   RTS
rcp_pow:
   TXA
   CLC
   ADC #7                                  ; S = sh + 7
   STA zp_br_r_s
   RTS
.endscope                                   ; (the recip scope — its close
                                            ; sat after the srecip data in
                                            ; the old layout)

; (The rot variant entries + gen thunks + rot_pair_thunk DELETED
;  2026-08-11 — the legacy rot machinery died with rot_w_pages.)
