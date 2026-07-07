
br_bbox_visible:
.scope
PAGE BANK_L2                            ; bbox + angle tables (TA/VATOX) live in bank L2
; --- bca_boxp = ROM_BBOX + node_id*16 + side*8, exploiting the base's
; page alignment (asserted by the loaders): the record never straddles a
; page, so lo = (node & 15)<<4 | side<<3 and hi = base_hi + (node >> 4)
; — byte-at-a-time, no 16-bit shift chain. Node ids are u8. ---
LDA zp_node_chlo
LSR A
LSR A
LSR A
LSR A
CLC
ADC zp_rom_bbox_hi
STA $87
LDA zp_node_chlo
ASL A
ASL A
ASL A
ASL A
LDX zp_bbox_side
BEQ bv_side_done
ORA #8
bv_side_done:
STA $86

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
