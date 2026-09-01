; CB interp mul, mirrored-table variant: |dy| BAKED into 4 operand bases
; (bake = 4 lo-byte pokes; all hi bytes constant by construction),
; offset rides X.  Body includes the den//2 round-add so the bracket
; matches the engine's umul_round_div..udiv16_8 span.
zp_mul_b = $D9
zp_prod_l = $DA
zp_prod_h = $DB
zp_div_den = $DC

.segment "CODE"
.global cb_bake, cb_body, cb_bdone, cb_done
cb_bake:                       ; A = new M (|dy|)
   STA m_sl+1
   STA m_sh+1
   EOR #$FF
   CLC
   ADC #1
   STA m_dl+1
   STA m_dh+1
cb_bdone:
   NOP

cb_body:
   LDX zp_mul_b
m_sl: LDA $0200,X              ; f(off+M) lo   (SQR_L page-aligned: lo byte = M)
   SEC
m_dl: SBC $0600,X              ; f(|off-M|) lo (SQRN_L: base $0700-M, hi const $06)
   STA zp_prod_l
m_sh: LDA $0400,X
m_dh: SBC $0800,X
   STA zp_prod_h
   LDA zp_div_den
   LSR A
   CLC
   ADC zp_prod_l
   STA zp_prod_l
   BCC cb_done
   INC zp_prod_h
cb_done:
   NOP
