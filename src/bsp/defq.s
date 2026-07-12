bsp_b_start:

; ============================================================================
; DEFERRED OP QUEUE (DEFQ) — clip-span mutations postponed to subsector end.
;
; Python's packed_render_seg appends ('solid', ...) / ('tighten', ...)
; tuples to a `deferred` list instead of mutating the span list mid-
; subsector; packed_render_subsector then applies them IN SEG ORDER (a
; tighten applied early would move span anchors a later sibling's
; mark_solid depends on). This is the 6502 equivalent: a flat byte queue
; at DEFQ_BASE ($0600, one 256-byte page), tail offset in DEFQ_TAIL,
; drained by defq_drain at subsector end.
;
; Entry formats (byte stream, no alignment):
;   solid:   $00, ilo, ihi
;   tighten: $01, ilo, ihi, top_block, bot_block
;     block = count, count × (xl, yl, xr, yr)   — a snapshot of the DCL's
;             TOP_RECORDS ($0700) / BOT_RECORDS ($0800) buffers, which
;             later segs' line emission would overwrite before the drain.
; ilo/ihi ($C2/$C3) = seg screen-x range clamped to u8 by the seg loop
; (subsector.s ms_setrange). On overflow the op is DROPPED and DEFQ_OVF
; set (debug flag; queue sized so this does not happen on E1M1).
; ============================================================================

; defq_append_solid — append ($00, ilo, ihi) from $C2/$C3 to the op queue.
;   Inputs:  $C2/$C3 = ilo/ihi, DEFQ_TAIL. Clobbers A, X.
;   Queues a mark_solid(ilo, ihi) — Python's ('solid', x_lo, x_hi, ...).
defq_append_solid:
.scope
   LDX DEFQ_TAIL
   CPX #$FD
   BCS dqs_ovf
; need 3 bytes
   LDA #0
   STA DEFQ_BASE,X
   INX
   LDA zp_ilo
   STA DEFQ_BASE,X
   INX
   LDA zp_ihi
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
; each block is (count, 4*count bytes) copied from $0700 / $0800.
; Caller guarantees at least one count is non-zero.
;   Inputs:  $C2/$C3 = ilo/ihi; $0700/$0800 = top/bot record blocks
;            (count byte + records) written by the DCL during this seg's
;            yt/yb line emission. Clobbers A, X, Y, zp_br_t0/t1.
;   The records-driven tighten (SC_TIGHTEN_FROM_RECORDS) replays these at
;   drain time — Python's ('tighten', x_lo, x_hi, sx1, sx2, yt.., yb..)
;   deferred entry, with the interpolated boundary data carried as DCL
;   verdict records instead of endpoint values.
;   Overflow policy: all size checks funnel to dqt_ovf BEFORE any byte is
;   written, so a dropped op never leaves a partial entry in the queue.
defq_append_tighten:
.scope
; size check: 5 + 4*(tc+bc) must fit in the remaining queue space.
   LDA $0700
   CLC
   ADC $0800
   BCS dqt_ovf
; n = tc + bc
   STA zp_br_t0
   ASL A
   BCS dqt_ovf
; 2n
   ASL A
   BCS dqt_ovf
; 4n
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
   LDA zp_ilo
   STA DEFQ_BASE,X
   INX
   LDA zp_ihi
   STA DEFQ_BASE,X
   INX

; copy top block: 1 + 4*tc bytes from $0700
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

; copy bot block: 1 + 4*bc bytes from $0800
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

; defq_blocklen — A = record count (<= 42) → zp_br_t1 = 1 + 4*count.
; (Records are 4 bytes: xl,yl,xr,yr. Historically strided at 6 — the old
; verdict-record size — over-copying 2 stale bytes per record both ways.)
; No CLCs needed: 4*42 = 168, so no intermediate carry is possible.
defq_blocklen:
   ASL A
   ASL A
   ADC #1
   STA zp_br_t1
   RTS

; defq_drain — apply queued ops in seg order at subsector end. Mirrors
; Python's deferred loop: each op then `if clips.is_full(): return`.
;   Inputs:  DEFQ_BASE stream, DEFQ_TAIL; bank C already paged by caller
;            (subsector.s pages it before the tail-JMP here).
;   Effects: solid ops → SC_MARK_SOLID($C2,$C3); tighten ops → records
;            copied back to $0700/$0800, then SC_TIGHTEN_FROM_RECORDS.
;            After EACH op, SC_IS_FULL: screen fully occluded → stop
;            early (remaining ops can no longer change any span).
;   Note: DEFQ_TAIL is reset to 0 by the subsector-entry code, not here —
;         X (queue cursor) is saved in zp_br_t2 across the bank-C calls.
;
;   Pseudocode:
;     x = 0
;     while x < tail:
;         op, ilo, ihi = q[x], q[x+1], q[x+2];  x += 3
;         if op == 0: mark_solid(ilo, ihi)
;         else:       restore top/bot records; tighten_from_records()
;         if is_full(): break
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
   STA zp_ilo
   LDA DEFQ_BASE,X
   INX
   STA zp_ihi
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
; ev_clamp_evy16 — clamp the endpoint struct's evy (VX1+0,X) to s8 range.
; Called with C = carry-out of (vyhi + bit7(vylo)), i.e. the rounding add
; that produced evy. evy16 hi byte = vyext + C. The vertex fits
; s8 iff that hi byte is the sign-extension of the lo byte. (The old
; `vyext != 0 → clamp` collapsed every behind-the-viewer vertex to
; evy=-128, corrupting crossing math: t = (1-evy_C)<<8/(evy_U-evy_C)
; needs the true evy_C — e.g. evy=-4 became -128 and a crossed solid
; wall projected sx=-2560 instead of Python's -2176.)
;
;   Inputs:  C flag (carry-out of the rounding add — do NOT touch C
;            before the ADC below), zp_br_vyext (s24 extension byte),
;            X = zp_seg_ep (struct offset), VX1+0,X = rounded evy lo byte.
;   Output:  VX1+0,X clamped to [-128, 127] iff evy16 exceeds s8. X kept.
;   Case map (hi = vyext + C):
;     hi == $00: lo < $80 fits, else clamp to +$7F   (128..255)
;     hi == $FF: lo >= $80 fits, else clamp to -$80  (-256..-129)
;     hi other:  clamp to +$7F / -$80 by sign of hi.
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
   LDA VX1+0,X
   BMI ev_done
; $FF:%1xxxxxxx → fits s8
   LDA #$80
   BNE ev_store
; -256..-129 → clamp
ev_case_zero:
   LDA VX1+0,X
   BPL ev_done
; $00:%0xxxxxxx → fits s8
   LDA #$7F                                ; 128..255 → clamp
ev_store:
   STA VX1+0,X
ev_done:
   RTS
.endscope

; ============================================================================
; br_project_x_auto — project saved view-x (zp_v_xext:zp_v_xint . zp_v_xfrac)
; to screen X, choosing the 3-mul narrow path when the integer part fits
; s8 and the 5-mul wide path otherwise. Output: zp_br_resl/h = sx (s16).
;
;   Inputs:  zp_v_xext:zp_v_xint = s16 integer view-x, zp_v_xfrac = u8
;            fraction; zp_br_rhi/rlo = (M8, S) reciprocal.
;   Output:  zp_br_resl/h = sx (s16), zp_br_resext = s24 extension so
;            callers (bbox corner path) can classify off-screen sides
;            uniformly whichever path ran.
;   Both paths are bit-exact with Python's full-width fp_project_x_subpx
;   (mod 2^16 at the s16 interface); wide-vx segs must still be projected
;   — their mark_solid/draws count (see br_seg_xform_vertex notes).
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


vc_bit_mask:
   .byte 1, 2, 4, 8, 16, 32, 64, 128       ; 1 << (idx & 7) for the vertex cache
                                        ; (from main_tail.s; MAIN at ceiling)
bsp_b_end:
; (B-region ceiling retired 2026-07-12: B floats in the one CODE region.)

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
