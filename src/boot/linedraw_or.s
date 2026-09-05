.segment "CODE"
; ONE VARIANT since 2026-09-05: the flat build (ORG $7500) was dead
; output -- nothing loaded it.  ORG $A200 comes from cfg/linedraw_or_banked.cfg
; and moves with RASTER_ENTRY (abi.inc / clip/arith.s); the blob is
; position-DEPENDENT (absolute self-refs + a JMP-indirect core dispatch).
; linedraw_or.s — build wrapper for the OR-mode NJ line rasteriser.
; Assembles raster/nj-linedraw4-or.s (+ the Hamiltonian 1:2-band shallow
; module) at $A200 with the engine's ZP assignments, and saves the raw
; image as linedraw_or_reloc.bin, which banked_bsp.py loads verbatim into
; bank C.  Entry point linedraw4 is the first byte.
;
; Feature flags:
;   HAMILTONIAN_12  specialised shallow core for the 1:2..1:1 slope band ON
;   STEEP_COMPACT   compact-loop steep core OFF — the unrolled steep blocks
;                   are -3.01 cyc/px and fit the $A200-$ADFF home
;   HAMILTONIAN_23  2:3-band module OFF (measured +0.036% only)

; ZP interface (must match the engine's zp map):
;   scrstrt      in: framebuffer page hi ($58/$6C)
;   x0,y0,x1,y1  in: line endpoints (trashed — x1/y1 reused as a jump vector)
;   scr,cnt,err,errs,ls,b,dx,dy: scratch owned by the rasteriser
scr = $74
scrstrt = $70
cnt = $79
err = $76
errs = $7A
dx = $80
dy = $81
x0 = $82
y0 = $83
x1 = $84
y1 = $85
ls = $86
b = $87

HAMILTONIAN_12 = 1
STEEP_COMPACT = 0
HAMILTONIAN_23 = 0

   .include "raster/nj-linedraw4-or.s"
   .include "raster/shallow_12_hamiltonian-or.s"
.if ::HAMILTONIAN_23
   .include "raster/shallow_23_hamiltonian-or.s"
.endif

