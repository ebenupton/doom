; --- CPU target: every builder MUST pass -D C02=0 (plain 6502) or -D C02=1
;     (enable 65C02 opcodes). STZ/INC A/PHX/etc are gated on C02 throughout. ---
.if ::C02
.setcpu "65C02"
.endif
; ZERO addr: zero a byte. 65C02 = STZ (A preserved); 6502 = LDA #0:STA (A
; clobbered) — only use where A is dead afterwards.
.macro ZERO a1, a2, a3, a4, a5, a6
.if ::C02
STZ a1
.ifnblank a2
STZ a2
.endif
.ifnblank a3
STZ a3
.endif
.ifnblank a4
STZ a4
.endif
.ifnblank a5
STZ a5
.endif
.ifnblank a6
STZ a6
.endif
.else
   LDA #0
   STA a1
.ifnblank a2
   STA a2
.endif
.ifnblank a3
   STA a3
.endif
.ifnblank a4
   STA a4
.endif
.ifnblank a5
   STA a5
.endif
.ifnblank a6
   STA a6
.endif
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

; BUMP_CC: A = A + 1 at a site where C is PROVEN CLEAR (document the
; proof at each use — Eben's carry survey, 2026-07-26). Both CPUs:
; ADC #1, 2 cyc — the NMOS arm's CLC dies. Writes C/V like BUMP's ADC,
; so the out-flags must be dead.
.macro BUMP_CC
   ADC #1
.endmacro

; span clipper (src/clip/*) -- 6502 span-clipper module for the DOOM-style
; BSP renderer.  ONE MODULE of the single ld65 engine link (it was a
; standalone beebasm unit historically; the old "span_clip.asm" name
; survives as src/span_clip.s, the include shell that pulls in the 13
; fragments in link order: clip/header.s (this file), arith.s, pool.s,
; interp.s, mark_solid.s, query.s, dcl.s, tfr.s, plot_axis.s,
; dcl_s16.s, vplot.s, rotvar.s, fbclear.s.
;
; This module manages a linked list of 'spans' representing the visible
; aperture on each horizontal column of the screen.
;
; EVERYTHING HERE IS HALF-OPEN (the native-representation decree,
; 2026-08-20/21, clip_ref.py is the executable spec): every interval —
; the query/solid ABI (zp_i_l/zp_i_h, hi EXCLUSIVE), a span's active
; range [XSTART, XEND), a DCL record's column claim [xl, xr) — means
; [lo, hi).  The column domain is [0, 255): column 255 is permanently
; solid/nonexistent BY DECREE, so every edge fits u8 and there are no
; 9-bit cases.  The one boundary where ranges meet pixels is dcl->
; raster: an emitted line RUNS OUT to paint its exclusive right edge
; inclusively (Eben's run-out ruling — no -1 anywhere).
;
; Each span stores a line definition (top/bot Y at two anchor X's) and
; an active column range.  The BSP front-to-back traversal calls three
; main operations:
;   has_gap              -- is any column in [lo, hi) open?
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
; Access: LDX slot_number; LDA POOL_TXLO,X  (fast absolute indexed)
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
SEG_BANKC
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
;   span_mark_solid         remove the range [zp_i_l, zp_i_h) (solid)
;   span_has_gap            C=1 iff any span overlaps [zp_i_l, A) (A-hi,
;                           C-only verdict; A returns ihi value-preserved)
;   (span_is_full retired — SPAN_IS_NOT_FULL macro tests zp_head inline)
;   span_read               serialize span list to buffer at (zp_buf)
;   interp_store            A = line y at column A (u8 round-to-nearest)
;   draw_clipped_line       clip u8 line zp_line_* to spans, emit + records
;   tighten_from_records    narrow spans by consuming TOP/BOT_RECORDS
;   draw_clipped_line_s16   s16 line: pre-clip to u8 box, then DCL
;   umul8 / udiv16_8        arithmetic primitives (harness/profiler only —
;                           bsp_render carries LOCAL copies, 2026-07-12)
.export span_init, span_mark_solid
.export interp_store, draw_clipped_line
.export draw_clipped_line_s16, draw_clipped_line_s16_h
.export adyn_ctr                        ; emitted-segment counter: the BSP
                                        ; walk samples it around a far
                                        ; descent (dynamic always-descend)
.export dcl_emit_segment                ; UNCLIPPED emit: bsp/objects.s
                                        ; feeds it whole lines when the
                                        ; billboard is proven visible
.export dcl_pair_seek, dcl_pair_resume  ; the solid-pair entries (dcl.s)
.export fused_begin, fused_above_h, fused_below_h
.export fused_below_raw, fused_above_raw, fused_merge_range
.export dcl_vert_on                     ; vertical fastpath (dcl.s)
.export udiv16_8
.import umul8                           ; THE multiplier lives in bsp/header.s
                                        ; (main RAM — unified 2026-08-09)
