bsp_d_start:

; bsp_resolve_child — ch := children[zp_bbox_side] of node ch.
;   ptr = rom_nodes + id*16; child_r at +8, child_l at +10.
bsp_resolve_child:
.scope
PAGE BANK_L0                            ; nodes table lives in bank L0
; Node ids fit one byte (<= 235): id*16 via single-byte shifts.
LDA zp_node_chlo
LSR A
LSR A
LSR A
LSR A
STA zp_br_t1
LDA zp_node_chlo
ASL A
ASL A
ASL A
ASL A
CLC
ADC zp_rom_nodes_lo
STA zp_br_p
LDA zp_br_t1
ADC zp_rom_nodes_hi
STA zp_br_p_h
LDA zp_bbox_side
ASL A
CLC
ADC #8
TAY
LDA (zp_br_p),Y
STA zp_node_chlo
INY
LDA (zp_br_p),Y
STA zp_node_chhi
RTS
.endscope

bsp_d_end:
.if ::BANKED
; (ld65 writes this: SAVE "bsp_render_d_bk.bin", $3BC0, bsp_d_end, $3BC0)
.else
.assert bsp_d_end <= $09FB, error       ; $09FB-$09FD hold DEFQ_TAIL/OVF + corner idx
; (ld65 writes this: SAVE "bsp_render_d.bin", $0978, bsp_d_end, $0978)
.endif





; ============================================================================
; W REGION ($DAC0-$DFFF) — Y-projection cache. Free RAM between the
; harness-loaded bbox table (ends $D4BF) and the recip table ($E000);
; the cache arrays occupy $D4C0-$DABF. Loaded as bsp_render_w.bin.
;
; br_project_y is now a caching front for br_project_y_raw: the key is
; the COMPLETE input set (rhi, rlo, h), so a hit returns the previously
; computed value — bit-identical by construction. 58-64%% of projections
; repeat within a frame (measured); a raw projection costs ~315 cycles
; end-to-end, a hit ~45.
; ============================================================================
; VWHC y-projection cache: flat @ $D4C0; banked -> bank L2 ($A600). br_project_y
; (this code) -> banked low RAM ($3900, clipper-vacated space) since $DAC0 is in
; MOS-ROM space on a real Model B.
.if ::BANKED
VWHC_VALID = $A700
VWHC_RHI = $A800
VWHC_RLO = $A900
VWHC_H = $AA00
VWHC_LO = $AB00
VWHC_HI = $AC00
.segment "W_BK"
.else
VWHC_VALID = $D4C0
VWHC_RHI = $D5C0
VWHC_RLO = $D6C0
VWHC_H = $D7C0
VWHC_LO = $D8C0
VWHC_HI = $D9C0
.segment "W"
.endif
