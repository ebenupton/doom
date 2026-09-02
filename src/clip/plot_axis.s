; ============================================================================
; clip/plot_axis.s — clipper fragment 9 of 13 (module map: clip/header.s).
;
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
; RASTER_ZP_SCRSTRT.  PIXELS ARE INCLUSIVE of both ends — this is the
; ranges->pixels boundary: DCL stages its exclusive end column in X1
; and the plotters paint through it (the RUN-OUT ruling; the clipper's
; half-open ranges stop at the emit). Pixel-exact vs the NJ output (reference:
; nj_raster.py; the fb_gate.py harness named here previously is no
; longer in the tree, 2026-07-12).
; Callers: dcl.s only — the emit axis dispatch (des_dispatch) and the
; vertical fast path (dv_emit tail-calls plot_v).
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
; BIASED form (2026-07-11, same philosophy as plot_v's rewrite): the row
; bits (y&7) fold into the base pointer, so byte-column offsets are pure
; multiples of 8 — and the column DIFF (x1&$F8)-(x0&$F8) IS the right
; partial's Y offset. Both >>3 chains, the middle-count register and the
; Y+=8 walks cease to exist. Middles walk DESCENDING (TXA keeps N set
; through STA, so BMI is an always-taken loop-back); write order is
; left, right, then middles right-to-left — OR-writes commute.
.if ::BANKED
SEG_BANKCHOST                              ; host-only rasteriser body:
                                           ; region tail (prefix purity)
plot_h:
.scope
   LDA RASTER_ZP_Y0
   LSR A
   LSR A
   LSR A
   CLC
   ADC RASTER_ZP_SCRSTRT
   STA zp_tmp1
   LDA RASTER_ZP_X0
   AND #$F8
   STA zp_tmp2                              ; pure column base (for the diff)
   LDA RASTER_ZP_Y0
   AND #7
   ORA zp_tmp2
   STA zp_tmp0                              ; base = column | row bits
   LDA RASTER_ZP_X1
   AND #$F8
   SEC
   SBC zp_tmp2
   BEQ ph_single                            ; one byte: combined mask
   STA zp_plot_i                            ; diff = right partial's offset
; left partial at Y = 0
   LDA RASTER_ZP_X0
   AND #7
   TAX
.if ::C02
   LDA plot_lmask,X
   ORA (zp_tmp0)                           ; non-indexed indirect (STA (zp)
   STA (zp_tmp0)                           ;  is 5 cyc; the LDY died)
.else
   LDY #0
   LDA plot_lmask,X
   ORA (zp_tmp0),Y
   STA (zp_tmp0),Y
.endif
; right partial at Y = diff
   LDA RASTER_ZP_X1
   AND #7
   TAX
   LDY zp_plot_i
   LDA plot_rmask,X
   ORA (zp_tmp0),Y
   STA (zp_tmp0),Y
; middles at Y = diff-8 .. 8 (Y multiples of 8: SBC never borrows until 0)
   LDX #$FF
   SEC
ph_mid:
   TYA
   SBC #8
   TAY
   BEQ ph_done
   TXA
   STA (zp_tmp0),Y
   BMI ph_mid                               ; always: N=1 from TXA ($FF)
ph_done:
   RTS
ph_single:
; single byte: mask = lmask[x0&7] & rmask[x1&7], at Y = 0
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
.if ::C02
   ORA (zp_tmp0)                           ; non-indexed (see left partial)
   STA (zp_tmp0)
.else
   LDY #0
   ORA (zp_tmp0),Y
   STA (zp_tmp0),Y
.endif
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
; (plot_v loop body DELETED 2026-07-27: BOTH builds now use the
; unrolled-column dispatcher in clip/vplot.s — the flat copy landed in
; the recovered $6B00 window. plot_bmask above is its mask table.)
SEG_BANKC                                  ; back from BANKCHOST
.else
; FLAT = THE TUBE PARASITE.  It ships no framebuffer and no rasterisers:
; the copro runs the engine and EMITS draw commands, the host draws them.
; plot_h IS the resident glue's h-emitter slot (tubedrv SKIPTO &F610:
; diag/h/v at +0/+3/+6) -- an EQUATE, so the engine tail-calls the
; emitter directly and segment BANKC carries ZERO parasite-only bytes
; (2026-09-02 flat-first-class purge; the old 3-byte patch slot + the
; builder's poke are both gone).
::plot_h = $F613
.endif                                     ; ::BANKED
