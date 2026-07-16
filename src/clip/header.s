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

; span clipper (src/clip/*) -- 6502 span-clipper module for the DOOM-style
; BSP renderer.  ONE MODULE of the single ld65 engine link (it was a
; standalone beebasm unit historically; the old "span_clip.asm" name
; survives as src/span_clip.s, the include shell that pulls in, in this
; order: clip/header.s (this file), arith.s, pool.s, interp.s,
; mark_solid.s, query.s, dcl.s, tfr.s, plot_axis.s, dcl_s16.s).
;
; This module manages a linked list of 'spans' representing the visible
; aperture on each horizontal column of the screen (0-255).  Each span stores
; a line definition (top/bot Y at two anchor X's) and an active column range.
; The BSP front-to-back traversal calls three main operations:
;   has_gap              -- quick check whether any column in [lo,hi] is open
;   mark_solid           -- remove a column range entirely (wall occludes)
;   tighten_from_records -- narrow apertures from DCL segment records
; plus draw_clipped_line[_s16[_h]] -- clip a line to the spans and plot it.
; (The old per-span "tighten" entry is retired — see the note in query.s.)
;
; Callers (2026-07-12):
;   bsp module   -- .imports the routines directly (linker-resolved); see
;                   the SC_* alias block in src/bsp/header.s.  bbox.s +
;                   subsector.s call span_has_gap; subsector.s calls
;                   span_mark_solid / tighten_from_records; subsector.s +
;                   lo.s call draw_clipped_line_s16(_h) and
;                   seg_zero_rec_solid.
;   walk driver  -- walk_drv.asm pages bank C and JSRs span_init (real
;                   address via engine_syms.inc) once per frame.
;   Python harness -- span_clip_6502.py, entry addresses via the ld65
;                   symbol map (symmap.py).
; BANKED build: the caller must page BANK_C (ROMSEL) before ANY entry
; here; the flat build needs no paging.
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
; shared: mul output = div input

; --- BBC banked port (path B) ---
; BANKED is passed via ca65 -D BANKED=0|1 (never assigned here; C02 is
; passed the same way).
;   BANKED=0 : flat build — region CLIP $2000-$366F (engine_flat.cfg),
;              sqr tables @ $A500. Regression oracle.
;   BANKED=1 : clipper lives in sideways-RAM bank C @ $8000 (CLIP_BK
;              region, engine_banked.cfg); sqr tables move to low RAM
;              ($1C00, abi.inc SQR_BASE) so the bank-C clipper can reach
;              them (the flat $A500 is inside the $8000-$BFFF bank window
;              when paged).
.if ::BANKED
.segment "CLIP_BK"
.else
.segment "CLIP"
.endif

; Public entry points for other engine modules (bsp_render .imports
; these — the linker resolves the calls directly; the Python harness
; finds them through the symbol map). The fixed-slot jump table that
; used to sit here is GONE (2026-07-16): jump tables are forbidden as
; cross-module glue — cross-module calls are direct JSRs to these
; symbols. (span_has_gap / seg_zero_rec_solid are exported at their
; definitions in query.s / tfr.s.)
;
; Entry contracts (full I/O headers at each routine):
;   span_init               reset pool: free chain + one full-screen span
;   span_mark_solid         remove closed range [zp_i_l, zp_i_h] (solid)
;   span_has_gap            A=1 iff any span overlaps [zp_i_l, zp_i_h]
;   span_is_full            A=1 iff active list empty (screen occluded)
;   span_read               serialize span list to buffer at (zp_buf)
;   interp_store            A = line y at column A (u8 round-to-nearest)
;   draw_clipped_line       clip u8 line zp_line_* to spans, emit + records
;   tighten_from_records    narrow spans by consuming TOP/BOT_RECORDS
;   draw_clipped_line_s16   s16 line: pre-clip to u8 box, then DCL
;   umul8 / udiv16_8        arithmetic primitives (harness/profiler only —
;                           bsp_render carries LOCAL copies, 2026-07-12)
.export span_init, span_mark_solid, span_is_full
.export span_read, interp_store, draw_clipped_line
.export tighten_from_records, draw_clipped_line_s16, draw_clipped_line_s16_h
.export umul8, udiv16_8
