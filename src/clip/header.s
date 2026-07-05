; --- CPU target: every builder MUST pass -D C02=0 (plain 6502) or -D C02=1
;     (enable 65C02 opcodes). STZ/INC A/PHX/etc are gated on C02 throughout. ---
.if ::C02
.setcpu "65C02"
.endif
; ZERO addr: zero a byte. 65C02 = STZ (A preserved); 6502 = LDA #0:STA (A
; clobbered) — only use where A is dead afterwards.
.macro ZERO addr
.if ::C02
STZ addr
.else
LDA #0
STA addr
.endif
.endmacro

; BUMP: A = A + 1. 65C02 = INC A (no carry); 6502 = CLC : ADC #1. Use only
; where the carry/overflow OUT is dead (negate, single-byte increments).
.macro BUMP
.if ::C02
ina
.else
CLC
ADC #1
.endif
.endmacro

; span_clip.asm -- Standalone 6502 span-clipper for a DOOM-style BSP renderer
;
; This module manages a linked list of 'spans' representing the visible
; aperture on each horizontal column of the screen (0-255).  Each span stores
; a line definition (top/bot Y at two anchor X's) and an active column range.
; The BSP front-to-back traversal calls three main operations:
;   has_gap    -- quick check whether any column in [lo,hi] is still open
;   tighten    -- narrow the aperture top/bot using a new wall segment
;   mark_solid -- remove a column range entirely (wall fully occludes)
;
; All arithmetic uses 8-bit fixed point with quarter-square lookup tables
; for multiply and restoring division loops for divide.  The span pool is
; 32 slots in block layout at $0400; slot 0 is the null sentinel.
;
; Pool at POOL ($0400), 32 slots in block layout.  Slot 0 = null.
; Each field is a 32-byte block; slot N is at POOL_FIELD + N.
; Access: LDX slot_number; LDA POOL_XLO,X  (fast absolute indexed)
;
; Division by 256 (ex=0): just take high byte of multiply (shift, no loop).
; Otherwise: restoring division loop, 8 iterations.

; --- Build flags ---

; --- Code origin: $2000 in BBC Micro memory map ---
; (hoisted: the pinned umul8 at $2030 references these before the main
; equate block)
; shared: mul output = div input

; --- BBC banked port (path B) ---
; BANKED is passed via beebasm -D BANKED=0|1 (never assigned here).
;   BANKED=0 : flat build (ORG $2000, sqr @ $A500) — regression oracle.
;   BANKED=1 : clipper lives in sideways-RAM bank C @ $8000; sqr tables move
;              to low RAM ($1000) so the bank-C clipper can reach them (the
;              flat $A500 is inside the $8000-$BFFF bank window when paged).
.if ::BANKED
.segment "CLIP_BK"
.else
.segment "CLIPJT"
.endif

; Public entry points for other engine modules (bsp_render links against
; these; the Python harness finds them through the symbol map).
.export jt_init, jt_mark_solid, jt_has_gap, jt_is_full
.export jt_read, jt_interp_store, jt_draw_clip
.export jt_tighten_from_records, jt_draw_clip_s16, jt_umul8, jt_udiv16_8

; --- Jump table: fixed entry points for each public operation ---
; Callers (Python harness, game engine) JSR to $2000 + 3*N.
; JMP is 3 bytes, so entries are evenly spaced.
jt_init: JMP span_init                           ; $2000                                             ; |
jt_mark_solid: JMP span_mark_solid                     ; $2003                                             ; |
jt_has_gap: JMP span_has_gap                        ; $2009                                             ; |||
jt_is_full: JMP span_is_full                        ; $200C
jt_read: JMP span_read                           ; $200F
jt_interp_store: JMP interp_store                        ; $2012  (kept for test_interp verification)
jt_draw_clip: JMP draw_clipped_line                   ; $2015
jt_tighten_from_records: JMP tighten_from_records                ; $201B
jt_draw_clip_s16: JMP draw_clipped_line_s16               ; $201E
jt_umul8: JMP umul8                               ; $2021  (exported for bsp_render.asm)
jt_udiv16_8: JMP udiv16_8                            ; $2024  (exported for bsp_render.asm)

; umul8 pin: flat build pins it at $2030 (legacy; bsp_render now has its own
; local copy so the pin is no longer strictly needed, but kept to keep the flat
; build byte-identical). In the banked build the clipper is at $8000 and umul8
; just floats after the jump table — the pin must NOT fire (it would move the
; ORG backwards out of the bank window).
.if ::BANKED
; banked: umul8 floats after the jump table at $8000 (no pin)
.else
.segment "CLIP"
.endif
