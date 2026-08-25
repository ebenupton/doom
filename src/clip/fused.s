; ============================================================================
; clip/fused.s — the FUSED entry points (2026-08-25). The walker itself
; lives in clip/fusedw.s, INCLUDED BEFORE dcl_s16.s: the s16 pre-clip
; dispatches forward into fw_walk_line, and these entries call the s16
; wrappers — keeping every file-level edge left-to-right (the DAG rule;
; the first cut had dcl_s16 <-> fused cycles).
; ============================================================================
SEG_BANKC

; ============================================================================
; fused entries
; ============================================================================
fused_begin:                               ; once per seg / object
   ZERO FW_TOUCH
   RTS

; The COMMON CASE — a seg fully on screen — takes the fast lane: the
; entries test the four hi bytes themselves and stage fwl_* DIRECTLY
; from the VX slots / zp_seg_sx, entering the walk past its zp_line
; copy (fw_walk_staged). The old route staged zp_line_*, hopped through
; dcl16_fastu8's mode test and fw_walk_line's copy — double staging and
; two dispatches for every on-screen armed line. Off-screen lines fall
; to the s16 slow path with FW_MODE armed, exactly as before; armed
; lines therefore NEVER reach dcl16_fastu8, whose mode test died with
; this change (speeding every DISARMED line too — see dcl_s16.s).
fused_above_h:                             ; X = sy pair offset
.scope
   LDA #0
   BEQ fh_go
::fused_below_h:
   LDA #$80
fh_go:
   STA FW_SIDE
   LDA VX1+1,X                             ; y1 hi
   ORA VX2+1,X                             ; y2 hi
   ORA zp_seg_sx1_h
   ORA zp_seg_sx2_h
   BNE fh_slow
   LDA zp_seg_sx1_l
   STA fwl_xl
   LDA zp_seg_sx2_l
   CMP fwl_xl
   BEQ fh_vert                             ; 1-column seg: vertical path
   STA fwl_xr
   LDA VX1,X
   STA fwl_yl
   LDA VX2,X
   STA fwl_yr
   JMP fw_walk_staged                      ; A = yr rides into the derive
fh_vert:
; stage zp_line and take dcl's vertical (plot-only — verticals carry no
; tighten information, armed or not; degenerate point rejects)
   STA zp_line_xl_l
   STA zp_line_xr_l
   LDA VX1,X
   STA zp_line_yl_l
   CMP VX2,X
   BEQ fh_degen                            ; point: reject (old fp_degen)
   LDA VX2,X
   STA zp_line_yr_l
   JMP draw_clipped_line
fh_degen:
   RTS
fh_slow:
   LDA #$80
   STA FW_MODE
   JSR draw_clipped_line_s16_h             ; hi-nonzero: retests, goes slow
   ZERO FW_MODE
   RTS
.endscope

fused_below_raw:                           ; line already in zp_line_* (s16)
.scope
   LDA #$80
   BNE fr_go
::fused_above_raw:                         ; (harness entry)
   LDA #0
fr_go:
   STA FW_SIDE
   LDA zp_line_xl_h
   ORA zp_line_yl_h
   ORA zp_line_xr_h
   ORA zp_line_yr_h
   BNE fr_slow
   LDA zp_line_xl_l
   CMP zp_line_xr_l
   BEQ fr_vert                             ; vertical/degen: dcl's classify
   BCS fr_swap                             ; reversed (harness only —
                                        ; the art baker pre-orders)
fr_entry:
   JMP fw_walk_line                        ; copies zp_line -> fwl + walks
fr_swap:
   LDA zp_line_xl_l
   LDX zp_line_xr_l
   STX zp_line_xl_l
   STA zp_line_xr_l
   LDA zp_line_yl_l
   LDX zp_line_yr_l
   STX zp_line_yl_l
   STA zp_line_yr_l
   JMP fr_entry
fr_vert:
   LDA zp_line_yl_l
   CMP zp_line_yr_l
   BEQ fr_degen
   JMP draw_clipped_line                   ; vertical plot
fr_degen:
   RTS
fr_slow:
   LDA #$80
   STA FW_MODE
   JSR draw_clipped_line_s16
   ZERO FW_MODE
   RTS
.endscope

