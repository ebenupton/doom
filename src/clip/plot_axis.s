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

; --- plot_v: x = X0 (== X1), y from min(Y0,Y1) to max(Y0,Y1) ----------------
plot_v:
.scope
LDA RASTER_ZP_Y0
CMP RASTER_ZP_Y1
BCC pv_ordered
LDX RASTER_ZP_Y1
STA RASTER_ZP_Y1
STX RASTER_ZP_Y0
TXA
pv_ordered:
; A = y0. ptr: lo = x & $F8, hi = scrstrt + (y0>>3); Y = y0 & 7
PHA
LSR A
LSR A
LSR A
CLC
ADC RASTER_ZP_SCRSTRT
STA zp_tmp1
LDA RASTER_ZP_X0
AND #$F8
STA zp_tmp0
PLA
AND #7
TAY
; mask = bmask[x&7]
LDA RASTER_ZP_X0
AND #7
TAX
LDA plot_bmask,X
STA zp_tmp2
; count = y1 - y0 + 1
LDA RASTER_ZP_Y1
SEC
SBC RASTER_ZP_Y0
TAX
INX
pv_loop:
LDA (zp_tmp0),Y
ORA zp_tmp2
STA (zp_tmp0),Y
DEX
BEQ pv_done
INY
CPY #8
BNE pv_loop
LDY #0
INC zp_tmp1                             ; next char row (+256)
pv_cell:
; Y == 0 here: unroll whole 8-row cells while at least 8 pixels remain
CPX #8
BCC pv_loop
.repeat 8
LDA (zp_tmp0),Y
ORA zp_tmp2
STA (zp_tmp0),Y
INY
.endrepeat
TXA
SEC
SBC #8
TAX
BEQ pv_done
LDY #0
INC zp_tmp1                             ; next char row (+256)
JMP pv_cell
pv_done:
RTS
.endscope
