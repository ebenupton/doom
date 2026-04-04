; Build wrapper for NJ linedraw4 + Hamiltonian
; Assembles to raw binary for py65 simulation

ORG &2000

; ZP variable definitions (matching nj-linedraw4)
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

INCLUDE "line-test/nj-linedraw4.asm"
INCLUDE "line-test/shallow_12_hamiltonian.asm"

SAVE "linedraw.bin", &2000, P%
