; ============================================================================
; clip/fbclear.s — clipper fragment 13 of 13, last in the link (module
; map: clip/header.s). Framebuffer clears — bank C (Eben's call, 2026-08-16).
;
; These were three unrolled routines in walk_drv.asm at DRV_CLR ($2200),
; ~145 B of the driver's 1,229. Moving them here buys that back in main
; RAM, which is the scarce resource (304 B free across the whole 32K),
; and costs one ROMSEL write per call — nothing against a 5,120-byte
; clear. Bank C is the right home: it ships in per-CPU variants already
; (BANK1/BANK1C), so unlike L0/L2 there is no CPU-invariance constraint
; on what lives here, and both driver call sites page bank C for the
; plot-queue drain IMMEDIATELY afterwards, so the paging is free in
; practice.
;
; BANKED ONLY. The flat build is the py65 harness: its framebuffer is a
; single buffer at $EA00 and no driver runs, so there is nothing here to
; call and DV_BACKHI has no flat address at all.
;
; Each buffer is 20 pages. One INY/BNE loop with 20 unrolled STA abs,Y
; is 5 cycles/byte -- 25,600 cycles for a full buffer.
;
; NOTE (2026-08-16): the driver's comment here described a four-way
; split (clr58t/clr58b/clr6Ct/clr6Cb) into 10-page halves, "so
; flip_sched can clear the beam-passed top early while waiting for
; vsync to release the bottom". No such split ever existed in the code;
; the plot run-ahead queue (fb71e3a) solved that problem a different
; way. The comment is not carried over.
; ============================================================================
.if ::BANKED

.if ::BANKED
; The framebuffer clears are BANKED-ONLY: walk_drv is their only caller
; and the flat parasite has no framebuffer to clear (2026-08-30).
SEG_BANKC

.macro FB_CLEAR_BODY base
.local lp
   LDA #0
   TAY
lp:
   STA base+$000,Y
   STA base+$100,Y
   STA base+$200,Y
   STA base+$300,Y
   STA base+$400,Y
   STA base+$500,Y
   STA base+$600,Y
   STA base+$700,Y
   STA base+$800,Y
   STA base+$900,Y
   STA base+$A00,Y
   STA base+$B00,Y
   STA base+$C00,Y
   STA base+$D00,Y
   STA base+$E00,Y
   STA base+$F00,Y
   STA base+$1000,Y
   STA base+$1100,Y
   STA base+$1200,Y
   STA base+$1300,Y
   INY
   BNE lp
.endmacro

; fb_clr0 / fb_clr1 — clear one whole framebuffer. Clobbers A and Y.
.scope
::fb_clr0:
   FB_CLEAR_BODY SCREEN0
   RTS
.endscope

.scope
::fb_clr1:
   FB_CLEAR_BODY SCREEN1
   RTS
.endscope

; fb_clr_back — clear whichever buffer is hidden, per the driver's
; DV_BACKHI ($58 or $6C). Clobbers A and Y.
.scope
::fb_clr_back:
   LDA DV_BACKHI
   CMP #>SCREEN0
   BNE cb_one
   JMP fb_clr0
cb_one:
   JMP fb_clr1
.endscope

.endif
.else
; FLAT = THE TUBE PARASITE: no framebuffer, nothing to clear.  The
; driver still links against the clear entries (its flip path calls
; them); they are RTS stubs here and the tube glue owns the real flip
; protocol.
SEG_BANKC
::fb_clr0:
   RTS
::fb_clr1:
   RTS
::fb_clr_back:
   RTS
.endif
