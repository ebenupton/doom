---
name: 6502 clipper implementation plan
description: Standalone 6502 span clipper subsystem with linked-list spans, separate from existing doom_fe.asm
type: project
---

The 6502 clipper is being implemented as a STANDALONE subsystem, separate
from the existing doom_fe.asm binary. It will be integrated later.

Key design decisions:
- Compact ZP workspace at the TOP of ZP (e.g., $C0-$FF)
- Span workspace in main memory (linked list, not array)
- Each span is 7 bytes: 1 byte next pointer + 6 bytes data (xlo, xhi, tl, bl, tr, br)
- Free list for span allocation/deallocation
- NO thunking back to Python — all span ops are pure 6502
- Hooked into Python for comparison: each Python span op also calls the 6502
  version and results are compared

**Why:** The existing doom_fe.asm clipper uses the old slope/intercept representation.
The new endpoint representation (6 pixel-Y bytes per span) with the portal walk
is fundamentally different and will be integrated into doom_fe.asm once validated.

**How to apply:** When working on the 6502 clipper, remember it's standalone.
Don't modify doom_fe.asm. Use a new .asm file. Hook via fe6502.py's py65 emulator.
