; ============================================================================
; Axis-aligned plotters — the gradient census showed ~70% of all rasterised
; pixels live in perfectly horizontal or vertical segments, which the NJ
; rasteriser walks through its generic (per-pixel, error-tracked) machinery.
;
;   plot_h: horizontal run via byte strips — partial edge masks + $FF
;           middles, ~8 pixels per read-modify-write.
;   plot_v: vertical run via constant bit mask, no error logic; +1 within
;           the 8-scanline char cell, +256 (INC hi) across cells.
;
; Same interface as RASTER_ENTRY: RASTER_ZP_X0/Y0/X1/Y1 (unbiased screen
; coords, x0<=x1 guaranteed by the DCL emit), OR-mode writes, scrstrt in
; RASTER_ZP_SCRSTRT. Pixel-exact vs the NJ output (fb_gate.py verifies).
;
; Mode 4: addr = (scrstrt+ (y>>3)) : (x & $F8) + (y & 7); bit = $80 >> (x&7).
; ============================================================================

; left-edge masks: pixels from bit (x&7) rightward within the byte
plot_lmask:
   .byte $FF, $7F, $3F, $1F, $0F, $07, $03, $01
; right-edge masks: pixels from the byte's left through bit (x&7)
plot_rmask:
   .byte $80, $C0, $E0, $F0, $F8, $FC, $FE, $FF
; single-pixel masks
plot_bmask:
   .byte $80, $40, $20, $10, $08, $04, $02, $01

; ======================================================================
; PLOT_H: draw horizontal pixel run, y = Y0 (== Y1), x in [X0, X1]
;
; Input:  RASTER_ZP_X0/X1 (u8, X0 <= X1 guaranteed by DCL's emit),
;         RASTER_ZP_Y0 = row (unbiased 0-159), RASTER_ZP_SCRSTRT.
; Output: pixels OR'd into the mode-4 framebuffer.
;         Clobbers A,X,Y, zp_tmp0/1/2, zp_plot_i.
;
; In mode 4 the 8 pixels of one byte share a scanline, so a horizontal
; run is byte strips: partial masks at the two ends, solid $FF between.
; Successive byte columns on the SAME scanline are 8 bytes apart (one
; char cell), so the strip walk is just Y += 8 on one base pointer.
;
; pseudocode:
;   ptr = (scrstrt + (y>>3)) : (x0 & $F8);  Y = y & 7
;   if (x0>>3) == (x1>>3):
;       byte |= lmask[x0&7] & rmask[x1&7]          # run within one byte
;   else:
;       byte |= lmask[x0&7]                        # left partial
;       repeat (x1>>3)-(x0>>3)-1 times: Y += 8; byte = $FF   # middles
;       Y += 8; byte |= rmask[x1&7]                # right partial
; ======================================================================
; --- plot_h: y = Y0 (== Y1), x from X0 to X1 --------------------------------
plot_h:
.scope
; screen ptr: lo = x0 & $F8, hi = scrstrt + (y>>3); Y = y & 7
   LDA RASTER_ZP_Y0
   LSR A
   LSR A
   LSR A
   CLC
   ADC RASTER_ZP_SCRSTRT
   STA zp_tmp1
   LDA RASTER_ZP_X0
   AND #$F8
   STA zp_tmp0
   LDA RASTER_ZP_Y0
   AND #7
   TAY
; byte-count = (x1>>3) - (x0>>3); same byte -> combined mask
   LDA RASTER_ZP_X1
   LSR A
   LSR A
   LSR A
   STA zp_tmp2
   LDA RASTER_ZP_X0
   LSR A
   LSR A
   LSR A
   STA zp_plot_i                             ; current byte index (x>>3)
   CMP zp_tmp2
   BNE ph_multi
; single byte: mask = lmask[x0&7] & rmask[x1&7]
   LDA RASTER_ZP_X0
   AND #7
   TAX
   LDA plot_lmask,X
   STA zp_tmp2
   LDA RASTER_ZP_X1
   AND #7
   TAX
   LDA plot_rmask,X
   AND zp_tmp2
   ORA (zp_tmp0),Y
   STA (zp_tmp0),Y
   RTS
ph_multi:
; middle-byte count -> zp_plot_i (bytes strictly between first and last)
   LDA zp_tmp2
   SEC
   SBC zp_plot_i
   STA zp_plot_i                           ; = last-first (>=1); middles = n-1
; left partial byte
   LDA RASTER_ZP_X0
   AND #7
   TAX
   LDA plot_lmask,X
   ORA (zp_tmp0),Y
   STA (zp_tmp0),Y
; middle full bytes: same y&7 in every cell, cells 8 bytes apart -> walk Y
   LDX zp_plot_i
   DEX
   BEQ ph_right                            ; no middles
   CLC                                     ; Y+8 sums never carry (max $FF)
ph_mid:
   TYA
   ADC #8
   TAY
   LDA #$FF                                ; OR with $FF == unconditional set
   STA (zp_tmp0),Y
   DEX
   BNE ph_mid
ph_right:
; right partial byte (advance Y one more cell)
   TYA
   CLC
   ADC #8
   TAY
   LDA RASTER_ZP_X1
   AND #7
   TAX
   LDA plot_rmask,X
   ORA (zp_tmp0),Y
   STA (zp_tmp0),Y
   RTS
.endscope

; ======================================================================
; PLOT_V: draw vertical pixel run, x = X0 (== X1), y in [Y0, Y1]
;
; Input:  RASTER_ZP_X0 = column, RASTER_ZP_Y0/Y1 = row range (either
;         order — swapped in place if Y0 > Y1), RASTER_ZP_SCRSTRT.
; Output: pixels OR'd into the framebuffer.  Clobbers A,X,Y,
;         zp_tmp0/1/2; RASTER_ZP_Y0/Y1 may be exchanged.
;
; One constant bit mask, no error term.  Moving down one scanline
; inside an 8-row char cell is Y+1; crossing into the next cell row is
; Y=0 / ptr_hi+1 (+256, since one char row = 32 cells * 8 bytes).
;
; pseudocode:
;   if y0 > y1: swap
;   ptr = (scrstrt + (y0>>3)) : (x & $F8);  Y = y0 & 7
;   mask = bmask[x&7]; count = y1 - y0 + 1
;   loop: byte |= mask; if --count == 0 done
;         if ++Y == 8: Y = 0; ptr += 256
;         (whole 8-row cells unrolled 8x while count >= 8 and Y == 0)
; ======================================================================
; --- plot_v: x = X0 (== X1), y from min(Y0,Y1) to max(Y0,Y1) ----------------
; BOTTOM-UP rewrite (2026-07-11): the pixel mask rides X for the whole
; line (row op = TXA / ORA (zp),Y / STA (zp),Y); rows walk DESCENDING so
; DEY is simultaneously the step and the loop test (BPL) — no CPY #8
; boundary compare, no pixel counter. Partial cells BIAS the base
; pointer (base lo bits 0-2 are clear; ORA composes) so Y reaches 0
; exactly at the run's top pixel; full middle cells are an unrolled
; Y=7..0 ladder. Write order is reversed vs the old top-down walk —
; OR-writes commute, so the framebuffer is bit-identical.
plot_v:
.scope
   LDA RASTER_ZP_Y0
   CMP RASTER_ZP_Y1
   BCC pv_ord
   LDX RASTER_ZP_Y1
   STA RASTER_ZP_Y1
   STX RASTER_ZP_Y0
pv_ord:
; mask -> X for the whole line; column base lo -> zp_tmp0 (unbiased)
   LDA RASTER_ZP_X0
   AND #7
   TAX
   LDA RASTER_ZP_X0
   AND #$F8
   STA zp_tmp0
   LDA plot_bmask,X
   TAX
; bottom cell page: zp_tmp1 = scrstrt + (y1>>3); cells spanned -> zp_plot_i
   LDA RASTER_ZP_Y1
   LSR A
   LSR A
   LSR A
   STA zp_plot_i                            ; y1 cell#
   CLC
   ADC RASTER_ZP_SCRSTRT
   STA zp_tmp1
   LDA RASTER_ZP_Y0
   LSR A
   LSR A
   LSR A
   STA zp_tmp2                              ; y0 cell#
   LDA zp_plot_i
   SEC
   SBC zp_tmp2
   STA zp_plot_i
   BNE pv_multi
; --- single cell: rows (y0&7)..(y1&7); bias base to the run's top ---
   LDA RASTER_ZP_Y0
   AND #7
   ORA zp_tmp0
   STA zp_tmp0
   LDA RASTER_ZP_Y1
   SEC
   SBC RASTER_ZP_Y0
   TAY                                     ; Y = run length - 1
pv_lp1:
   TXA
   ORA (zp_tmp0),Y
   STA (zp_tmp0),Y
   DEY
   BPL pv_lp1
   RTS
pv_multi:
; --- bottom partial cell: rows 0..(y1&7) ---
   LDA RASTER_ZP_Y1
   AND #7
   TAY
pv_lp2:
   TXA
   ORA (zp_tmp0),Y
   STA (zp_tmp0),Y
   DEY
   BPL pv_lp2
   DEC zp_tmp1                              ; up one char row (-256)
   DEC zp_plot_i
   BEQ pv_top
; --- middle full cells: unrolled Y = 7..0 ladder ---
pv_mid:
   LDY #7
.repeat 7
   TXA
   ORA (zp_tmp0),Y
   STA (zp_tmp0),Y
   DEY
.endrepeat
   TXA
   ORA (zp_tmp0),Y
   STA (zp_tmp0),Y
   DEC zp_tmp1
   DEC zp_plot_i
   BNE pv_mid
pv_top:
; --- top partial: rows (y0&7)..7; bias so Y = 0 lands on row y0&7 ---
   LDA RASTER_ZP_Y0
   AND #7
   ORA zp_tmp0
   STA zp_tmp0
   LDA RASTER_ZP_Y0
   AND #7
   EOR #7
   TAY                                     ; Y = 7 - (y0&7)
pv_lp3:
   TXA
   ORA (zp_tmp0),Y
   STA (zp_tmp0),Y
   DEY
   BPL pv_lp3
   RTS
.endscope
