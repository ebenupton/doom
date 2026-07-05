
br_bbox_visible:
.scope
PAGE BANK_L2                            ; bbox + angle tables (TA/VATOX) live in bank L2
; --- Compute bbox table pointer = ROM_BBOX + node_id*16 + side*8 ---
LDA zp_node_chlo
STA zp_br_t0
LDA zp_node_chhi
STA zp_br_t1
ASL zp_br_t0
ROL zp_br_t1
ASL zp_br_t0
ROL zp_br_t1
ASL zp_br_t0
ROL zp_br_t1
ASL zp_br_t0
ROL zp_br_t1
; node_id * 16
LDA zp_bbox_side
BEQ bv_side_done
; side=1: add 8
LDA zp_br_t0
CLC
ADC #8
STA zp_br_t0
LDA zp_br_t1
ADC #0
STA zp_br_t1
bv_side_done:
CLC
LDA zp_rom_bbox_lo
ADC zp_br_t0
STA zp_br_p
LDA zp_rom_bbox_hi
ADC zp_br_t1
STA zp_br_p_h

; Point bca_boxp ($86/$87) at the ROM box; bbox_check_angle reads it via
; (bca_boxp),Y — no 8-byte copy into a work area.
LDA zp_br_p
STA $86
LDA zp_br_p_h
STA $87

; --- Angle-space visibility (px=$01, py=$03, ab=$FA2F preset per frame) ---
JSR BCA_CHECK
LDA bca_vis
BNE bv_anglevis
LDA #0
RTS
bv_anglevis:
LDA bca_ilo
STA $C2
LDA bca_ihi
STA $C3
PAGE BANK_C
JMP SC_HAS_GAP

.endscope
