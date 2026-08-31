; t16p — TRUE16-with-paging rotate variant (measurement unit, not engine code).
; Full 8-bit-mag quarter-square products on the page-decomposed frame:
;   vx = PB_X[page] + rns(+-ox*mag8s -+oy*mag8c, 3)
;   vy = PB_Y[page] + rns(+-ox*mag8c +-oy*mag8s, 3)
; Sum side keeps the base+mag SMC trick (2-byte poke, index reach 510 inside
; the 512-entry sqr tables); the diff side pays the classic abs staging the
; mirror can't cover at mag8 reach.  18-bit combine, #4-seeded, 3-byte floor
; shift.  Class bodies: general / sin-unity / cos-unity (the rig selects).
SQR_L   = $0200
SQR_H   = $0400
PB_XL   = $0A80
PB_XH   = $0A90
PB_YL   = $0AA0
PB_YH   = $0AB0
zp_d    = $28          ; ox
zp_dy   = $10          ; oy
zp_pg   = $2C          ; page nibble
zp_vxl  = $11
zp_vxh  = $12
zp_vyl  = $13
zp_vyh  = $14
zp_p1   = $60
zp_p2   = $62
zp_p3   = $64
zp_p4   = $66
zp_sl   = $68
zp_sm   = $69

.macro TP_PROD msite, ssl, ssh, src, dst
ssl: LDA $FFFF,X               ; SMC: SQR_L + M  (sum lo, X=o)
   STA dst
ssh: LDA $FFFF,X               ; SMC: SQR_H + M  (sum hi)
   STA dst+1
   LDA src
   SEC
msite: SBC #$00                ; SMC: #M
   BCS :+
   EOR #$FF
   ADC #1                     ; C clear on this path
:  TAX                        ; X = |o-M|
   LDA dst
   SEC
   SBC SQR_L,X
   STA dst
   LDA dst+1
   SBC SQR_H,X
   STA dst+1
.endmacro

.macro TP_UPROD src, dst
   LDA src
   STA dst+1
   LDA #0
   STA dst                    ; product = o<<8
.endmacro

; combine axis: seed #4, patched sign ops, 3-byte shift, PB fold
.macro TP_AXIS s1, l1, h1, b1, s2, l2, h2, b2, pa, pb_lo, pb_hi, vl, vh
   LDA #4
s1:CLC                        ; SMC sign 1
l1:ADC pa                     ; SMC ADC/SBC
   STA zp_sl
   LDA #0
h1:ADC pa+1
   STA zp_sm
   LDA #0
b1:ADC #0                     ; SMC byte2 op ($69/$E9)
   TAY
   LDA zp_sl
s2:SEC                        ; SMC sign 2
l2:SBC pb_lo
   STA zp_sl
   LDA zp_sm
h2:SBC pb_lo+1
   STA zp_sm
   TYA
b2:SBC #0                     ; SMC byte2 op
   CMP #$80
   ROR A
   ROR zp_sm
   ROR zp_sl
   CMP #$80
   ROR A
   ROR zp_sm
   ROR zp_sl
   CMP #$80
   ROR A
   ROR zp_sm
   ROR zp_sl
   CLC
   LDA vl,X                   ; X = page (abs,X PB read)
   ADC zp_sl
   STA vh                     ; placeholder — real ops below
.endmacro

.segment "CODE"
; ---------- general body ----------
.global t16p_gen
t16p_gen:
   LDX zp_d
   TP_PROD p1m, p1sl, p1sh, zp_d, zp_p1        ; P1 = ox*mag8s
   LDX zp_d
   TP_PROD p3m, p3sl, p3sh, zp_d, zp_p3        ; P3 = ox*mag8c
   LDX zp_dy
   TP_PROD p2m, p2sl, p2sh, zp_dy, zp_p2       ; P2 = oy*mag8c
   LDX zp_dy
   TP_PROD p4m, p4sl, p4sh, zp_dy, zp_p4       ; P4 = oy*mag8s
   JMP t16p_comb

; ---------- sin-unity body (mag8s == 256) ----------
.global t16p_suni
t16p_suni:
   TP_UPROD zp_d,  zp_p1
   TP_UPROD zp_dy, zp_p4
   LDX zp_d
   TP_PROD u3m, u3sl, u3sh, zp_d, zp_p3
   LDX zp_dy
   TP_PROD u2m, u2sl, u2sh, zp_dy, zp_p2
   JMP t16p_comb

; ---------- cos-unity body (mag8c == 256) ----------
.global t16p_cuni
t16p_cuni:
   TP_UPROD zp_d,  zp_p3
   TP_UPROD zp_dy, zp_p2
   LDX zp_d
   TP_PROD v1m, v1sl, v1sh, zp_d, zp_p1
   LDX zp_dy
   TP_PROD v4m, v4sl, v4sh, zp_dy, zp_p4
   JMP t16p_comb

; ---------- shared combine ----------
t16p_comb:
; x axis: S = sgn1*P1 + sgn2*P2 + 4 ; vx = PB_X[pg] + S>>3
   LDA #4
x1s:CLC
x1l:ADC zp_p1
   STA zp_sl
   LDA #0
x1h:ADC zp_p1+1
   STA zp_sm
   LDA #0
x1b:ADC #0
   TAY
   LDA zp_sl
x2s:SEC
x2l:SBC zp_p2
   STA zp_sl
   LDA zp_sm
x2h:SBC zp_p2+1
   STA zp_sm
   TYA
x2b:SBC #0
   CMP #$80
   ROR A
   ROR zp_sm
   ROR zp_sl
   CMP #$80
   ROR A
   ROR zp_sm
   ROR zp_sl
   CMP #$80
   ROR A
   ROR zp_sm
   ROR zp_sl
   LDX zp_pg
   CLC
   LDA PB_XL,X
   ADC zp_sl
   STA zp_vxl
   LDA PB_XH,X
   ADC zp_sm
   STA zp_vxh
; y axis
   LDA #4
y1s:CLC
y1l:ADC zp_p3
   STA zp_sl
   LDA #0
y1h:ADC zp_p3+1
   STA zp_sm
   LDA #0
y1b:ADC #0
   TAY
   LDA zp_sl
y2s:CLC
y2l:ADC zp_p4
   STA zp_sl
   LDA zp_sm
y2h:ADC zp_p4+1
   STA zp_sm
   TYA
y2b:ADC #0
   CMP #$80
   ROR A
   ROR zp_sm
   ROR zp_sl
   CMP #$80
   ROR A
   ROR zp_sm
   ROR zp_sl
   CMP #$80
   ROR A
   ROR zp_sm
   ROR zp_sl
   CLC
   LDA PB_YL,X
   ADC zp_sl
   STA zp_vyl
   LDA PB_YH,X
   ADC zp_sm
   STA zp_vyh
   RTS

; site table for the rig (label, purpose) — export addresses
.global p1m,p1sl,p1sh,p2m,p2sl,p2sh,p3m,p3sl,p3sh,p4m,p4sl,p4sh
.global u2m,u2sl,u2sh,u3m,u3sl,u3sh,v1m,v1sl,v1sh,v4m,v4sl,v4sh
.global x1s,x1l,x1h,x1b,x2s,x2l,x2h,x2b,y1s,y1l,y1h,y1b,y2s,y2l,y2h,y2b

; ---------- t16p2: mirrored signed-index diff tables (SQRN at $0600/$0800) ----------
; diff side = 2-byte SMC walk like the sum side: base = SQRN + 256 - M, X = o.
.macro TP_PROD2 ssl, dsl, ssh, dsh, dst
ssl: LDA $FFFF,X
   SEC
dsl: SBC $FFFF,X
   STA dst
ssh: LDA $FFFF,X
dsh: SBC $FFFF,X
   STA dst+1
.endmacro

.global t16p2_gen
t16p2_gen:
   LDX zp_d
   TP_PROD2 q1sl, q1dl, q1sh, q1dh, zp_p1
   TP_PROD2 q3sl, q3dl, q3sh, q3dh, zp_p3
   LDX zp_dy
   TP_PROD2 q2sl, q2dl, q2sh, q2dh, zp_p2
   TP_PROD2 q4sl, q4dl, q4sh, q4dh, zp_p4
   JMP t16p_comb
.global q1sl,q1dl,q1sh,q1dh,q2sl,q2dl,q2sh,q2dh,q3sl,q3dl,q3sh,q3dh,q4sl,q4dl,q4sh,q4dh
