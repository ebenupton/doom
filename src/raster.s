; ============================================================================
; raster.s — the NJ line rasteriser, IN THE ENGINE LINK.
;
; It used to be its own ca65/ld65 unit (src/boot/linedraw_or.s +
; cfg/linedraw_or_banked.cfg -> linedraw_or_reloc.bin), which banked_bsp.py
; then spliced into the bank C image at a hardcoded offset.  Three things
; were wrong with that and all three die here:
;
;   * the blob named its thirteen zero-page bytes as LITERALS while the
;     engine let ld65 allocate RASTER_ZP_*.  They agreed by luck.  In-link
;     the equates sit next to the reservations they mirror and the assert
;     below is a build error rather than a wrong picture.
;   * RASTER_ENTRY was an abi.inc CONSTANT that had to be kept equal to
;     wherever Python happened to splice the bytes.  The linker owns the
;     address now and the assert pins the constant to it.
;   * the $A200-$ADFF budget was a Python `assert len(rast) <= ...`.  It is
;     a cfg region, so ld65 refuses an overrun at link time.
;
; BANKED ONLY.  The flat image has no rasteriser -- its RASTER_ENTRY is a
; 3-byte stub the tube builder patches to the resident emitters -- so the
; segment is empty there and the cfg marks it optional.
; ============================================================================
.if ::BANKED

.segment "RASTER"

; ZP interface.  These MUST equal the engine's own reservations; the
; asserts below are the whole point of being in the same link.
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

.importzp RASTER_ZP_SCRSTRT, RASTER_ZP_X0, RASTER_ZP_Y0
.importzp RASTER_ZP_X1, RASTER_ZP_Y1
.assert scrstrt = RASTER_ZP_SCRSTRT, error, "raster scrstrt != zp.inc"
.assert x0 = RASTER_ZP_X0, error, "raster x0 != zp.inc"
.assert y0 = RASTER_ZP_Y0, error, "raster y0 != zp.inc"
.assert x1 = RASTER_ZP_X1, error, "raster x1 != zp.inc"
.assert y1 = RASTER_ZP_Y1, error, "raster y1 != zp.inc"

; Feature flags:
;   HAMILTONIAN_12  specialised shallow core for the 1:2..1:1 slope band ON
;   STEEP_COMPACT   compact-loop steep core OFF — the unrolled steep blocks
;                   are -3.01 cyc/px and fit the $A200-$ADFF home
;   HAMILTONIAN_23  2:3-band module OFF (measured +0.036% only)
HAMILTONIAN_12 = 1
STEEP_COMPACT = 0
HAMILTONIAN_23 = 0

   .include "boot/raster/nj-linedraw4-or.s"
   .include "boot/raster/shallow_12_hamiltonian-or.s"

; The entry is the segment's first byte.  The clipper CALLS IT BY NAME now
; (clip/arith.s aliases RASTER_ENTRY to this import), so the old
; RASTER_ENTRY = $A200 literal is gone and the address is the linker's.
.export linedraw4

.endif
