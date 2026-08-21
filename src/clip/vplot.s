; ============================================================================
; clip/vplot.s — clipper fragment 11 of 13 (module map: clip/header.s).
; Unrolled vertical-column rasteriser (both builds; banked primary).
; Eben's design, 2026-07-27:
;
;   160 unrolled row-plot blocks (one per screen row), TWO copies (one
;   per framebuffer $5800/$6C00), a shared lo index table + per-copy hi
;   tables of each block's address MINUS ONE (161 entries: entry 160 is
;   the trailing RTS, for inclusive y1 = 159), and two dispatch bodies.
;
;   A vertical [y0, y1] at column X: the dispatch SMC-arms an RTS over
;   block y1+1's first opcode (restoring the previous arm first), then
;   computed-JMPs into block y0 via PHA/PHA/RTS. The run falls straight
;   down the blocks and the armed RTS returns to plot_v's CALLER (the
;   dcl sites tail-call here, exactly as the old loop's RTS did).
;
;   Row block is 7 bytes / 11 cycles (mask rides Y — one better than
;   the LDA zp form):
;         TYA                                        2
;         ORA FB + (row/8)*256 + (row&7),X           4  (never crosses:
;         STA FB + (row/8)*256 + (row&7),X           5   lo = 0-7 + X<=248)
;   Mode-4 char rows are 256-byte aligned (32 cols x 8), so with
;   X = column*8 the row operand is FB + (y>>3)<<8 + (y&7).
;
;   addr-1 tables serve BOTH consumers: PHA/PHA/RTS wants block-1, and
;   the RTS arm writes at entry+1 (one ADC #1, done once per call).
;   The restore value is $98 (TYA, every block's first opcode); the
;   trailing-RTS slot may transiently hold $98 — it is only ever
;   executed on a y1=159 call, which re-arms it to $60 first.
;
;   Copy selection reads RASTER_ZP_SCRSTRT (bit 5 splits $58/$6C), so
;   the driver's existing back-buffer flip (walk_drv `LDA backhi:STA
;   &70`) steers the dispatch with ZERO driver changes. (The SMC-at-
;   flip variant from the spec would save ~7 cycles per call — ~10
;   calls/frame — at the cost of driver coupling; deliberately traded.)
;
;   Placement: cfg region VPLOTC, bank C $B200-$BFFF (the vertex-span
;   descriptor tables moved to the $A500-$A8FF HUD-blob gap to free
;   this window; verticals already run under ambient bank C, zero
;   paging). Flat build (2026-07-27 recovery): ONE copy in VPLOTF
;   ($6B00), tables+dispatch CODE-resident — see the .else arm.
; ============================================================================
.macro VPLOT_COL fb
.repeat 160, R
   TYA
   ORA fb + ((R/8)*256) + (R & 7),X
   STA fb + ((R/8)*256) + (R & 7),X
.endrepeat
   RTS                                     ; entry-160 target (y1 = 159)
.endmacro

; one dispatch body per copy (per-copy SMC restore state + hi table)
.macro VPLOT_DISPATCH hitab, blk
.scope
; CONTRACT (2026-07-27): Y0 <= Y1 REQUIRED. dv and the descriptor walk
; emit ordered by construction; the des trampoline (dcl.s des_to_v)
; normalizes its own rare arrivals. Equal draws one pixel.
   LDA #$98                                ; TYA: un-arm the previous stop
vpd_rst:
   STA blk + 7*160                         ; SMC operand; init = trailing
                                           ; RTS (dormant until first arm)
   LDX RASTER_ZP_Y1
   INX
   LDA vptab_lo,X
   CLC
   ADC #1                                  ; entry+1 = block y1+1's opcode
   STA zp_tmp1
   STA vpd_rst+1
   LDA hitab,X
   ADC #0
   STA zp_tmp2
   STA vpd_rst+2
   LDA #$60                                ; RTS: arm the stop
.if ::C02
   STA (zp_tmp1)                           ; non-indexed (the LDY died)
.else
   LDY #0
   STA (zp_tmp1),Y
.endif
   LDY RASTER_ZP_Y0                        ; push block y0 - 1
   LDA hitab,Y
   PHA
   LDA vptab_lo,Y
   PHA
   LDA RASTER_ZP_X0
   AND #7
   TAY
   LDA plot_bmask,Y
   TAY                                     ; Y = pixel mask (blocks TYA it)
   LDA RASTER_ZP_X0
   AND #$F8
   TAX                                     ; X = column byte offset
   RTS                                     ; enter block y0
.endscope
.endmacro

.if ::BANKED
.segment "VPLOTC"
.align $100
vpblk0:
   VPLOT_COL $5800                         ; SCREEN0 copy
.align $100
vpblk1:
   VPLOT_COL $6C00                         ; SCREEN1 copy
; the shared lo table REQUIRES page congruence between the copies
.assert <vpblk0 = <vpblk1, error, "vplot copies not page-congruent"

vptab_lo:                                   ; shared: <(block addr - 1)
.repeat 161, R
   .byte <(vpblk0 + 7*R - 1)
.endrepeat
vptab0_hi:
.repeat 161, R
   .byte >(vpblk0 + 7*R - 1)
.endrepeat
vptab1_hi:
.repeat 161, R
   .byte >(vpblk1 + 7*R - 1)
.endrepeat


plot_v:
   LDA RASTER_ZP_SCRSTRT
   AND #$20                                ; $58 -> 0, $6C -> $20
   BNE vp_fb1
   VPLOT_DISPATCH vptab0_hi, vpblk0
vp_fb1:
   VPLOT_DISPATCH vptab1_hi, vpblk1

.else
; ============================================================================
; FLAT build (2026-07-27, after the $6B00 recovery): ONE framebuffer
; ($EA00), ONE copy in the VPLOTF region ($6B00-$6F60), tables and the
; single dispatch as CODE-resident data/code (the RECIP_S precedent
; — CODE tail had 858 B free). No copy select: plot_v IS the dispatch.
; ============================================================================
.segment "VPLOTF"
.align $100
vpblk0:
   VPLOT_COL $EA00                         ; the flat/copro framebuffer
.segment "CLIPF"                            ; flat-only support: lives with
                                            ; the bank-C-equivalent ABOVE the
                                            ; 22K line (bottom-22K identity)
vptab_lo:                                   ; <(block addr - 1)
.repeat 161, R
   .byte <(vpblk0 + 7*R - 1)
.endrepeat
vptab0_hi:
.repeat 161, R
   .byte >(vpblk0 + 7*R - 1)
.endrepeat
plot_v:
   VPLOT_DISPATCH vptab0_hi, vpblk0

.endif                                     ; ::BANKED
