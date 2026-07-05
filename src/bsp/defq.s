bsp_b_start:

; defq_append_solid — append ($00, ilo, ihi) from $C2/$C3 to the op queue.
defq_append_solid:
.scope
LDX DEFQ_TAIL
CPX #$FD
BCS dqs_ovf
; need 3 bytes
LDA #0
STA DEFQ_BASE,X
INX
LDA $C2
STA DEFQ_BASE,X
INX
LDA $C3
STA DEFQ_BASE,X
INX
STX DEFQ_TAIL
RTS
dqs_ovf:
LDA #1
STA DEFQ_OVF
RTS
.endscope

; defq_append_tighten — append ($01, ilo, ihi, top block, bot block) where
; each block is (count, 6*count bytes) copied from $0700 / $0800.
; Caller guarantees at least one count is non-zero.
defq_append_tighten:
.scope
; size check: 5 + 6*(tc+bc) must fit in the remaining queue space.
LDA $0700
CLC
ADC $0800
BCS dqt_ovf
; n = tc + bc
STA zp_br_t0
ASL A
BCS dqt_ovf
; 2n
STA zp_br_t1
ASL A
BCS dqt_ovf
; 4n
CLC
ADC zp_br_t1
BCS dqt_ovf
; 6n
CLC
ADC #5
BCS dqt_ovf
; entry size
CLC
ADC DEFQ_TAIL
BCS dqt_ovf
; tail + size > 255 → drop

LDX DEFQ_TAIL
LDA #1
STA DEFQ_BASE,X
INX
LDA $C2
STA DEFQ_BASE,X
INX
LDA $C3
STA DEFQ_BASE,X
INX

; copy top block: 1 + 6*tc bytes from $0700
LDA $0700
JSR defq_blocklen
LDY #0
dqt_cp_top:
LDA $0700,Y
STA DEFQ_BASE,X
INX
INY
CPY zp_br_t1
BNE dqt_cp_top

; copy bot block: 1 + 6*bc bytes from $0800
LDA $0800
JSR defq_blocklen
LDY #0
dqt_cp_bot:
LDA $0800,Y
STA DEFQ_BASE,X
INX
INY
CPY zp_br_t1
BNE dqt_cp_bot

STX DEFQ_TAIL
RTS
dqt_ovf:
LDA #1
STA DEFQ_OVF
RTS
.endscope

; defq_blocklen — A = record count (<= 42) → zp_br_t1 = 1 + 6*count.
; No CLCs needed: 6*42 = 252, so no intermediate carry is possible.
defq_blocklen:
ASL A
STA zp_br_t1
ASL A
ADC zp_br_t1
ADC #1
STA zp_br_t1
RTS

; defq_drain — apply queued ops in seg order at subsector end. Mirrors
; Python's deferred loop: each op then `if clips.is_full(): return`.
defq_drain:
.scope
LDX #0
dd_loop:
CPX DEFQ_TAIL
BCS dd_done
LDA DEFQ_BASE,X
INX
STA zp_br_t3
; type
LDA DEFQ_BASE,X
INX
STA $C2
LDA DEFQ_BASE,X
INX
STA $C3
LDA zp_br_t3
BNE dd_tighten
; solid: mark_solid(ilo, ihi), no line emission.
STX zp_br_t2
JSR SC_MARK_SOLID                       ; (bank C paged by caller)
JMP dd_after
dd_tighten:
; restore top block to $0700
LDA DEFQ_BASE,X
JSR defq_blocklen
LDY #0
dd_cp_top:
LDA DEFQ_BASE,X
STA $0700,Y
INX
INY
CPY zp_br_t1
BNE dd_cp_top
; restore bot block to $0800
LDA DEFQ_BASE,X
JSR defq_blocklen
LDY #0
dd_cp_bot:
LDA DEFQ_BASE,X
STA $0800,Y
INX
INY
CPY zp_br_t1
BNE dd_cp_bot
STX zp_br_t2
JSR SC_TIGHTEN_FROM_RECORDS             ; (bank C paged by caller)
dd_after:
JSR SC_IS_FULL                          ; (bank C paged by caller)
BNE dd_done
LDX zp_br_t2
JMP dd_loop
dd_done:
RTS
.endscope

; ============================================================================
; ev_clamp_evy16 — clamp zp_seg_cur_evy to s8 range using the s24 view-y.
; Called with C = carry-out of (vyhi + bit7(vylo)), i.e. the rounding add
; that produced zp_seg_cur_evy. evy16 hi byte = vyext + C. The vertex fits
; s8 iff that hi byte is the sign-extension of the lo byte. (The old
; `vyext != 0 → clamp` collapsed every behind-the-viewer vertex to
; evy=-128, corrupting crossing math: t = (1-evy_C)<<8/(evy_U-evy_C)
; needs the true evy_C — e.g. evy=-4 became -128 and a crossed solid
; wall projected sx=-2560 instead of Python's -2176.)
; ============================================================================
ev_clamp_evy16:
.scope
LDA zp_br_vyext
ADC #0
; hi byte of rounded evy16
BEQ ev_case_zero
CMP #$FF
BEQ ev_case_ff
ASL A
BCS ev_clamp_neg
; carry = sign of hi byte
LDA #$7F
BNE ev_store
ev_clamp_neg:
LDA #$80
BNE ev_store
ev_case_ff:
LDA zp_seg_cur_evy
BMI ev_done
; $FF:%1xxxxxxx → fits s8
LDA #$80
BNE ev_store
; -256..-129 → clamp
ev_case_zero:
LDA zp_seg_cur_evy
BPL ev_done
; $00:%0xxxxxxx → fits s8
LDA #$7F                                ; 128..255 → clamp
ev_store:
STA zp_seg_cur_evy
ev_done:
RTS
.endscope

; ============================================================================
; br_project_x_auto — project saved view-x (zp_v_xext:zp_v_xint . zp_v_xfrac)
; to screen X, choosing the 3-mul narrow path when the integer part fits
; s8 and the 5-mul wide path otherwise. Output: zp_br_resl/h = sx (s16).
; ============================================================================
br_project_x_auto:
.scope
; Narrow iff xext equals the sign-extension of xint's bit 7.
LDA zp_v_xint
ASL A
; C = sign of int part
LDA #0
ADC #$FF
EOR #$FF
; A = $FF if C else $00
CMP zp_v_xext
BNE a_wide
LDA zp_v_xint
STA zp_br_t0
LDA zp_v_xfrac
STA zp_br_t1
JSR br_project_x_subpx
; Narrow sx always fits s16 (|evx|<=127, rxh<=127 → |sx|<=16383);
; set the s24 extension byte so callers can classify uniformly.
LDX #0
LDA zp_br_resh
BPL a_pos
DEX
a_pos:
STX zp_br_resext
RTS
a_wide:
JMP br_project_x_wide
.endscope

bsp_b_end:
.if ::BANKED
; (ld65 writes this: SAVE "bsp_render_b_bk.bin", $3A40, bsp_b_end, $3A40)
.else
.assert bsp_b_end <= $0C00, error
; (ld65 writes this: SAVE "bsp_render_b.bin", $0AA0, bsp_b_end, $0AA0)
.endif

; ============================================================================
; D REGION ($0978-$09FF) — near-plane edge-crossing math for bbox
; visibility. Free space after span_clip's LC_* scratch ($0958) and the
; BBOX_CORNERS/DEFQ vars ($0960-$0976). Loaded as bsp_render_d.bin.
; ============================================================================
.if ::BANKED
.segment "D_BK"                         ; above PAGE (directly *LOAD-able)
.else
.segment "D"
.endif
