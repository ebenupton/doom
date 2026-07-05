ORG &A900

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

INCLUDE "line-test/nj-linedraw4-or.asm"
INCLUDE "line-test/shallow_12_hamiltonian-or.asm"

SAVE "linedraw_or_reloc.bin", &A900, P%
