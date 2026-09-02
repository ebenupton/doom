; linedraw_or_reloc.asm — build wrapper for the OR-mode NJ line rasteriser.
; Assembles raster/nj-linedraw4-or.asm (+ the Hamiltonian 1:2-band shallow
; module) at $A900 with the engine's ZP assignments, and saves the raw image
; as linedraw_or_reloc.bin — loaded verbatim by the harnesses/engine builds
; (banked_bsp.py, span_clip_6502.py; the entry point linedraw4 is at $A900).
;
; Feature flags:
;   HAMILTONIAN_12  specialised shallow core for the 1:2..1:1 slope band ON
;   STEEP_COMPACT   compact loop steep core ON (replaces the 16 unrolled
;                   steep blocks; pixel-identical)
;   HAMILTONIAN_23  2:3-band module OFF (measured +0.036% only)
IF FLATORG
ORG &7500                       \ flat: above-line (2026-08-09 full sub-22K
                                \ alignment — $2000-$2BFF is the shared
                                \ driver reservation now)
ELSE
ORG &A200                       \ banked: bank C window home. MUST equal
                                \ RASTER_ENTRY (abi.inc / clip/arith.s).
                                \ $A800 -> $A300 -> $A200 (2026-09-02, two C compactions);
                                \ budget $A200-$ADFF, VPLOTC above at $AE00.
                                \ Position-DEPENDENT (absolute self-refs +
                                \ an internal JMP-indirect core dispatch), so
                                \ this ORG and RASTER_ENTRY move together.
ENDIF

; ZP interface (must match the engine's zp map):
;   scrstrt      in: framebuffer page hi ($58/$6C)
;   x0,y0,x1,y1  in: line endpoints (trashed — x1/y1 reused as a jump vector)
;   scr,cnt,err,errs,ls,b,dx,dy: scratch owned by the rasteriser
scr = &74
scrstrt = &70
cnt = &79
err = &76
errs = &7A
dx = &80
dy = &81
x0 = &82
y0 = &83
x1 = &84
y1 = &85
ls = &86
b = &87

HAMILTONIAN_12 = TRUE
IF FLATORG
STEEP_COMPACT = TRUE            \ flat: compact loops (blob must fit $7500-
                                \ $7FFF; steep is ~1% of suite pixels)
ELSE
STEEP_COMPACT = FALSE           \ banked: unrolled steep restored 2026-08-11
                                \ (-3.01 cyc/px measured; fits the $A800 home)
ENDIF
HAMILTONIAN_23 = FALSE

INCLUDE "raster/nj-linedraw4-or.asm"
INCLUDE "raster/shallow_12_hamiltonian-or.asm"
IF HAMILTONIAN_23
INCLUDE "raster/shallow_23_hamiltonian-or.asm"
ENDIF

IF FLATORG
SAVE "linedraw_or_flat.bin", &7500, P%
ELSE
SAVE "linedraw_or_reloc.bin", &A200, P%
ENDIF
