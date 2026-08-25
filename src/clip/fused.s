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

fused_above_h:                             ; X = sy pair offset
   LDA #0
   BEQ fa_go
fused_below_h:
   LDA #$80
fa_go:
   STA FW_SIDE
   LDA #$80
   STA FW_MODE
   JSR draw_clipped_line_s16_h
   ZERO FW_MODE
   RTS

fused_below_raw:                           ; line already in zp_line_* (s16)
   LDA #$80
   BNE fr_go
fused_above_raw:                           ; (harness entry)
   LDA #0
fr_go:
   STA FW_SIDE
   LDA #$80
   STA FW_MODE
   JSR draw_clipped_line_s16
   ZERO FW_MODE
   RTS

