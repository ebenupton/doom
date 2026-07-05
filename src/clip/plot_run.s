; ============================================================================
; plot_run — run-slice plotter for shallow diagonals.
;
; Reproduces the NJ rasteriser's EXACT pixel pattern (recurrence proven
; against 16,120 oracle-extracted run sequences — the whole 4*dy<=dx band,
; both y directions; tools/run_oracle.py + the derivation check):
;
;   dx = q*dy + rem                       (one u8/u8 divide)
;   row 1:        n = (dx>>1)/dy + 1  ==  (q>>1) + 1        [halving identity]
;                 r = (dx>>1) mod dy ==  ((q&1)*dy + rem) >> 1
;   rows 2..dy:   r += rem; n = q, or q+1 when r >= dy (then r -= dy)
;   row dy+1:     n = remaining pixel count
;
; The y-ascending case's runs are the reverse sequence, which equals
; traversing from (X1,Y1) right-to-left with the SAME forward sequence —
; so both directions share one recurrence, y always stepping DOWN in
; screen coords... (up in y-value: we start from the higher-y end).
;
; Each row's run is plotted by plot_h (byte strips) via RASTER_ZP_X0/X1/Y0.
; Dispatched from dcl_emit_segment for 8*dy <= dx (threshold measured).
; ============================================================================
plot_run:
.scope
; --- direction + cursor seed: start at the HIGHER-y endpoint ---
LDA RASTER_ZP_Y1
SEC
SBC RASTER_ZP_Y0
BCS pr_from_p1                          ; Y1 >= Y0: start at (X1,Y1), x desc
EOR #$FF                                ; C clear: dy = Y0-Y1 via negate
ADC #1
STA zp_run_dy
LDA #0
STA zp_run_dir                          ; x ascending
LDA RASTER_ZP_X0
STA zp_run_x
LDA RASTER_ZP_Y0
STA zp_run_y
JMP pr_setup
pr_from_p1:
STA zp_run_dy                           ; dy = Y1-Y0 (>0: equal filtered out)
LDA #1
STA zp_run_dir                          ; x descending
LDA RASTER_ZP_X1
STA zp_run_x
LDA RASTER_ZP_Y1
STA zp_run_y
pr_setup:
; --- dx = X1-X0 (dispatch guarantees X0 < X1) = pixels-1 ---
LDA RASTER_ZP_X1
SEC
SBC RASTER_ZP_X0
STA zp_run_left
; --- q, rem = divmod(dx, dy): 8-iteration u8/u8 restoring divide ---
LDA #0                                  ; remainder accumulator
LDX #8
pr_div:
ASL zp_run_left                         ; dividend shifts out high-first...
ROL A
CMP zp_run_dy
BCC pr_div_no
SBC zp_run_dy
INC zp_run_left                         ; quotient bit into vacated bit 0
pr_div_no:
DEX
BNE pr_div
LDX zp_run_left                         ; X = quotient q
STA zp_run_rem                          ; A = remainder
STX zp_run_q
; restore left = dx (consumed by the divide)
LDA RASTER_ZP_X1
SEC
SBC RASTER_ZP_X0
STA zp_run_left
; --- first-run seed via the halving identity ---
TXA                                     ; q
LSR A                                   ; A = q>>1, C = q&1
STA zp_run_n
INC zp_run_n                            ; n1 = (q>>1)+1
LDA zp_run_rem
BCC pr_r_done
CLC
ADC zp_run_dy                           ; (q odd) + dy: dy<=63, rem<dy -> <=126
pr_r_done:
LSR A
STA zp_run_r
; rows = dy+1
LDX zp_run_dy
INX
STX zp_run_rows
; --- row loop ---
pr_row:
LDA zp_run_y
STA RASTER_ZP_Y0
LDA zp_run_dir
BNE pr_xdesc
; x ascending: run = [x, x+n-1]
LDA zp_run_x
STA RASTER_ZP_X0
CLC
ADC zp_run_n
STA zp_run_x                            ; cursor -> x+n (next run start)
SEC
SBC #1
STA RASTER_ZP_X1
JMP pr_plot
pr_xdesc:
; x descending: run = [x-n+1, x]
LDA zp_run_x
STA RASTER_ZP_X1
SEC
SBC zp_run_n
STA zp_run_x                            ; cursor -> x-n
CLC
ADC #1
STA RASTER_ZP_X0
pr_plot:
JSR plot_h                              ; clobbers A/X/Y + zp_tmp*/zp_plot_i
; --- bookkeeping ---
LDA zp_run_left
SEC
SBC zp_run_n
STA zp_run_left
DEC zp_run_rows
LDA zp_run_rows
CMP #1
BCC pr_done                             ; 0 rows left -> done
BEQ pr_last
; interior row: n = q (+1 when r+rem wraps)
LDA zp_run_r
CLC
ADC zp_run_rem
CMP zp_run_dy
BCC pr_nq
SBC zp_run_dy                           ; C set from CMP
STA zp_run_r
LDX zp_run_q
INX
STX zp_run_n
JMP pr_ystep
pr_nq:
STA zp_run_r
LDA zp_run_q
STA zp_run_n
JMP pr_ystep
pr_last:
LDX zp_run_left
INX
STX zp_run_n                            ; last run = remaining pixels
pr_ystep:
DEC zp_run_y                            ; traversal always walks y upward
JMP pr_row
pr_done:
RTS
.endscope
