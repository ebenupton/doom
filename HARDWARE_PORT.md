# BBC Micro hardware port — working notes

Target: **Model B + sideways-RAM board**, framebuffers in main RAM, incremental
occlusion (per-seg bank flips). (ACCCON/shadow is Master-only — not used.)

## Memory map (planned)

```
LOW RAM ($0000-$57FF = 22K)
  $0000-$01FF  ZP + stack
  $0200-$0BFF  workspace: pool, records, line-out, tfs, BSP stack, visited, ptrs
  $0C00-$1B3A  vcache (3.6K) + valid            (no shrink needed)
  ~$1B40       shared MATH module (umul8/umul16x16/udiv16_8/udiv32_16) ~0.5K
  ~$1D40       sqr/sqr2 tables (1K)             ← low: used by both phases
  ~$2140       BSP walk + transform + project + overflow blobs + angle  ~6.4K
  $3A00-$57FF  free (~7.5K)
  $5800-$6BFF  framebuffer 0 (5K)
  $6C00-$7FFF  framebuffer 1 (5K)
BANK C ($8000-$BFFF): clipper (~9K) + rasteriser (3.2K) = ~12.2K
BANK L0: nodes 3776 + ssectors 948 + seg-hdrs 7920 + verts 1868 = 14512
BANK L1: bbox 3776 + FHCH 3960 + VWH 1206 + recip 1154 + sincos 128 = 10224
```

## Confirmed on jsbeeb (spike, 2026-06-21) — model B-DFS1.2

- **SWRAM paging:** `STA $FE30` (ROMSEL) pages banks; banks 4 & 5 are
  independent physical RAM (verified write/switch/read-back from executing 6502
  code). Save/restore current bank via `$F4` (OS copy) keeps the OS/BASIC alive
  across a paged call. Banks 4-7 expected RAM (4,5 confirmed; check 6,7 when used).
- **Framebuffers:** two 5K buffers stack at $5800 (FB0) and $6C00 (FB1) in the
  mode-4 10K region; both fillable.
- **Double-buffer flip:** CRTC R12/R13 = `addr>>3`. $5800→$0B00 (R12=$0B,R13=$00),
  $6C00→$0D80 (R12=$0D,R13=$80). Write via $FE00=reg / $FE01=val. **Confirmed
  visually** — flip works once `SEI` blocks the OS 50Hz vsync handler (which
  otherwise reloads R12/R13 to its own copy each frame). In the solo build we
  SEI and own R12/R13. Display wraps within the 10K region (top from start addr,
  wrapping past $8000 back to $5800).

## Partition rule (what goes where)

- Level data → banks L0/L1 (read only during BSP walk / projection).
- Clipper + rasteriser + occlusion-pool ops (HAS_GAP/IS_FULL/MARK_SOLID/TIGHTEN)
  → bank C. Must NOT read level data (true today: works on pool + projected
  endpoints in low RAM + framebuffer).
- **Shared math (umul8/umul16x16/udiv16_8/udiv32_16) + sqr tables → low RAM** —
  called from BOTH the transform (data-bank phase) and the clipper (bank-C
  phase). bsp_render calls SC_UMUL8=$2030 / SC_UDIV16_8=$2024 today; these live
  in span_clip, so they must be extracted low before the clipper moves to bank C.
- Pool/records/line-list/vcache/workspace → low RAM (touched every phase).

## Flip cadence
Per node/seg the BSP walk alternates data-bank reads with bank-C pool ops + clip
+ raster; shared math needs no flip (low). ~5-8 `STA $FE30`/seg, <1% of frame.

## Verification harness (banked_mem.py) — built + unit-tested 2026-06-21

`banked_mem.py` models $FE30 SWRAM banking for the py65 flat-memory harness by
overriding __setitem__ only: a $FE30 write swaps the active 16K bank in/out of
the flat $8000-$BFFF window (reads stay fast/unmodified). Unit-tested in py65:
write distinct bytes to banks 4 & 5, switch, read back — `$70=$11`, `$71=$AA`,
identical to the jsbeeb spike. This is the fast oracle for verifying a banked
build bit-exact against the flat reference before jsbeeb confirmation.

## Codebase reality (discovered 2026-06-21)

There are TWO renderers:
- **doom_fe.asm** (257K) — a COMPLETE banked, bootable, integrated build with its
  OWN renderer (`bsp_traverse`, `mark_solid`, `tighten`, `umul8x8`) and its own
  clipper (`clipper_bank2.bin` @ $9B20 in bank 2). Shipped via `doom_loader.asm`
  + `build_ssd.py` → `doom_e1m1.ssd` (BANK0/1/2 + CODE@$22D2 + RECIP@$4F7E +
  QSQ@$5400). This is the LEGACY renderer (the approximation), but the
  boot/bank/CRTC/keyboard infra is proven and reusable. Its layout INDEPENDENTLY
  CONFIRMS the budget plan (sqr low @$5400, recip low @$4F7E, 3 data banks).
- **span_clip.asm + bsp_render.asm** — the ACCURATE records-driven clipper fixed
  this session (4 clip-bug fixes). Flat/emulator-only (BspRender6502). NOT in a
  banked/bootable form.

"Running on hardware" = port the accurate clipper into a banked bootable build.

## jsbeeb boot of the existing (legacy) disc — status

Built `doom_e1m1.ssd` and booted on jsbeeb. Loader runs (prints "DOOM E1M1",
DFS *LOAD works — $3000 staging populated). BUT the game loop does not render:
post-run CODE@$22D2 reads as zeros and PC has crashed (~$0D2E). Banks 0-2 accept
writes. Root cause not yet isolated (off the critical path — it's the legacy
build). Likely candidates: game-loop crash zeroing memory, a CODE-load overlap
with $3000 staging ($22D2-$4F47 overlaps $3000-$6FFF staging), or a jsbeeb
bank/DFS timing quirk. Not pursued further — the goal is the new clipper.

## DECISION POINT (needs user) — port path

The remaining work is large and forks on one structural decision:
  (A) **Retrofit** the accurate records-driven clipper into doom_fe.asm's proven
      banked framework (reuse loader/CRTC/keyboard/game-loop; swap render path).
      Pro: reuses working boot+display+input. Con: deep surgery in 257K of legacy
      code; reconcile ZP maps, data-bank layout, entry points, packed_layout.
  (B) **Fresh banking** around the standalone span_clip/bsp_render, reusing only
      doom_loader's proven layout constants (sqr@$5400, recip@$4F7E, 3 banks,
      CRTC setup). Pro: clean, built on the code I verified this session, with
      the banked_mem.py oracle. Con: re-implement boot/keyboard glue.

Recommendation: **(B)** — build fresh banking around the standalone accurate
modules, verified with banked_mem.py then jsbeeb, lifting doom_loader.asm's
proven CRTC/keyboard/bank-copy code verbatim. Keeps us on the verified clipper
and avoids entangling with the legacy renderer.

### Next steps once (B) is chosen
1. Re-layout span_clip.asm via multi-ORG/SAVE (beebasm resolves intra-file labels
   across ORGs, as bsp_render.asm already does): math primitives
   (umul8/umul16x16/udiv16_8/udiv32_16) + sqr tables LOW; clipper body + raster @
   $8000 (bank C). Repoint bsp_render SC_UMUL8/SC_UDIV16_8 to the low math addrs.
2. bsp_render: set rom pointers to L0/L1 window addresses; insert STA $FE30 bank
   selects at the data-read vs pool-op/clip boundaries (per-seg cadence).
3. Build L0/L1/C bank images; verify the whole thing bit-exact vs the flat
   BspRender6502 using banked_mem.py (BankedBspRender6502).
4. Adapt doom_loader.asm (bank-copy + CRTC + keyboard) for the new entry point;
   build .ssd; boot on jsbeeb; compare framebuffer to the flat reference.

## PROGRESS (path B, 2026-06-22) — clipper banking DONE + verified

Done and committed:
1. **Math decoupling** — bsp_render has its own umul8/udiv16_8 (.SC_UMUL8/.SC_UDIV16_8
   labels, low RAM); no longer JSRs the clipper's math. Flat regression GREEN
   (bit-exact). [commit: bsp_render local umul8/udiv16_8]
2. **Conditional banked build** — span_clip.asm takes beebasm `-D BANKED=0|1`.
   BANKED=1 → clipper @ $8000 (bank C), sqr tables → low RAM $1000, umul8 pin
   dropped → `span_clip_bankc.bin`. Flat sites pass `-D BANKED=0`. Flat regression
   byte-identical.
3. **Bank-C clipper VERIFIED bit-exact** — `banked_dcl_test.py` runs the bank-C
   clipper via banked_mem.py (sqr @ $1000, $FE30-paged) vs the flat clipper:
   **40000 random cases + directed, 0 mismatches.** The hard part is proven.

## REMAINING (path B) — data banking + bsp_render paging, then boot

Bank layout (chosen to give ~3 page-flips/seg):
  L0 (bank, ~14.6K): nodes(3776) ss(948) seg_hdr(7920) verts(1868) sincos(128)
  L1 (bank, ~10.1K): bbox(3776) FHCH(3960) VWH(1206) recip(1154)
  C  (bank): clipper (span_clip_bankc.bin) + rasteriser (relocate linedraw here)
  LOW: sqr@$1000, bsp_render code+math, workspace, vcache, framebuffers $5800-$7FFF

PAGE macro (no-op when BANKED=0, so flat stays bit-exact; A-safe = place only at
A-dead points): `MACRO PAGE b : IF BANKED : LDA #b : STA &FE30 : ENDIF : ENDMACRO`.

Invariant to avoid restore logic: every data-reading routine PAGEs its bank at
entry; every clip-op call PAGEs C before the JSR; loop tops that read data after
a clip re-PAGE. Insert points (identified):
  - br_node_setup, bsp_resolve_child  -> PAGE L0 (nodes)
  - br_bbox_visible / bbox_check       -> PAGE L1 (bbox)
  - br_render_subsector entry + seg-loop top -> PAGE L0 (ss/seg_hdr/verts/sincos)
  - projection (FHCH/VWH/recip read)   -> PAGE L1
  - 9 clip-op JSRs (lines ~1051,1641,1679,1715,1738,1754,2209,2227,2229)
    -> PAGE C before each (args are in ZP, so A is free — A-safe)
Then: set zp_rom_* bases to $8000-window offsets (conditional); build L0/L1
images (split packed_rom_main + recip into the two bank layouts); write
BankedBspRender6502 (banked_mem: L0/L1/C banks + sqr low + rasteriser in C) and
verify its framebuffer == flat BspRender6502 bit-exact at several positions.
Finally: adapt doom_loader.asm (bank-copy + CRTC 256x160 + keyboard, all proven)
for the new entry; build .ssd; boot on jsbeeb; compare to flat reference.

This remaining work is invasive but mechanical; the banked_mem.py oracle gives
bit-exact verification at each step before jsbeeb. The novel risk (paged code +
low tables) is already retired by the bank-C clipper result.

## MILESTONE (2026-06-22): full renderer runs banked, bit-identical to flat

Both halves of the banking now verified end-to-end against the flat reference
via banked_mem.py:
- Clipper in bank C: 40000 dcl_test cases, 0 mismatches.
- FULL renderer (ROM_MAIN -> bank L0, clipper+rasteriser -> bank C, sqr+FHCH ->
  low, paged via $FE30): banked_bsp.py, all reference positions + a 448-position
  sweep -> 0 differences. ~0.5-1% paging overhead. Flat regression ALL GREEN.

Key bug found+fixed during bring-up: PAGE inserts in the $0AA0 _b (defq) blob
grew it from 324->339 bytes, overrunning the zp_rom_* pointers at $0BE8 ->
corrupted zp_rom_bbox -> BCA culled everything. Fix: page bank C ONCE before
JMP defq_drain (defq only does clip ops), drop the per-op PAGEs inside defq.
Also: br_bbox_visible's JMP SC_HAS_GAP tail-call needed PAGE C (JMP-form clip
calls were missed by the JSR-only first pass).

## REMAINING for real-HW jsbeeb boot

On a Model B, $C000-$FFFF is MOS ROM — every table/cache currently there must
move. Still resident at $C000+ (flat in the model, must relocate):
  bbox $C600, VWHC cache $D4C0, bsp_render_w (yproj) $DAC0, recip $E000,
  VWH $E484, angle module code $E940, angle tables $DC00/$F200/$F601.
Plan: bbox + recip + VWH + angle tables -> bank L1; angle module code + VWHC
cache + yproj code -> low RAM (clipper vacated $2000-$47FF, ~10K free; sqr@$2000,
FHCH@$2400 already there). Then PAGE L1 around recip/VWH/bbox/angle-table reads,
verify bit-exact via banked_bsp, then adapt doom_loader.asm + boot on jsbeeb.

## VERIFICATION BOUNDARY (2026-06-22)

banked_mem.py models the $8000-$BFFF window but has RAM everywhere else, incl.
$C000-$FFFF. So it has ALREADY verified everything the model can: the full
renderer running with ROM_MAIN in bank L0 + clipper/raster in bank C, paged via
$FE30, bit-identical to flat (448 positions). The remaining $C000+ relocation
does NOT change renderer logic — it only moves bytes out of MOS-ROM space — so
the model would show it "passing" without proving the real-HW constraint. Its
real test is jsbeeb (real banking + real MOS ROM at $C000+). The novel,
risky part (paged code calling low tables; per-seg bank cadence; correct PAGE
placement) is DONE and proven.

### Full $C000+ inventory to relocate for real HW (jsbeeb phase)
Bank L2 (bank 7) <- TA_LO($DC00,1024) TA_HI($F200,1025) VATOX($F601,1025)
  bbox($C600,3776) recip($E000,1028) VWH($E484,1206) VWHC cache($D4C0,1536)
  = 10620B, fits 16K.
Low RAM (clipper-vacated $2000-$47FF) <- angle module code (slope_div.asm,
  ORG $E940->~$3400, 1234B), br_project_y/bsp_render_w (ORG $DAC0->~$3F00),
  bca workspace ($FA10-$FA32, 35B -> ~$0300; shared by slope_div.asm +
  bsp_render.asm lines 555/556/1423-1426 + harness mem[0xFA2F]).
PAGE L2 points: br_bbox_visible (angle tables+bbox; angle code runs low, reads
  L2), br_project_y (recip+VWH+VWHC).
Edits: slope_div.asm ORG+3 tables+~15 bca defs conditional; bsp_render.asm
  RECIP_BASE/VWHC/bsp_render_w-ORG/BCA_CHECK/bca-refs conditional + 2 PAGE L2;
  harness/loader build L2 image + low angle/bca. Then adapt doom_loader.asm
  (copy 4 banks 4/5/6/7; CRTC 256x160; keyboard; relocate-down) -> .ssd ->
  boot jsbeeb -> compare framebuffer to flat at known positions.

## MILESTONE 2 (2026-06-22): full $C000+ relocation done — real-HW-ready layout

The renderer now uses NO addresses above the $8000 bank window except sideways
RAM. Verified bit-identical to flat (all reference positions + 252-position
sweep, 0 diffs; flat regression GREEN). Final banked map:
  bank 4 (L0): ROM_MAIN (nodes/ss/seg_hdr/verts)
  bank 6 (C):  clipper ($8000) + rasteriser ($A900)
  bank 7 (L2): TA_LO$8000 TA_HI$8400 VATOX$8900 bbox$8E00 recip$9D00 VWH$A200
               VWHC$A700
  low: sqr$2000 FHCH$2400 angle-code$3400 br_project_y$3900 bca-ws$3A00
       bsp_d$0978 bsp_b$0AA0 vcache$0C00 bsp_lo$1B40 bsp_render$4800
  framebuffers $5800/$6C00.
This should run on a real BBC Model B + sideways RAM. banked_bsp.py is the
model oracle; jsbeeb is the real-HW test.

## REMAINING: boot packaging (task 9)

Need a bootloader + (eventually) a 6502 game loop. Scoped:
- Build disc: 3 bank images (-> banks 4/6/7) + low-RAM regions + bootloader.
- Most low regions are >= PAGE ($1900) so *LOAD-able directly; only bsp_d
  ($0978, 42B) + bsp_b ($0AA0, 339B) are below PAGE -> load high + copy down
  after disc I/O, or embed in the loader and copy after SEI.
- Per-frame setup (currently done by the Python harness) for a fixed spawn can
  be PRECOMPUTED and poked: ZP_PX/PY (8.8), ZP_VZ, ZP_PXRAW/PYRAW, sincos
  (SMAG/SNEG/SONE/CMAG/CNEG/CONE), bca_ab ($3A2F). (A real game loop needs a
  6502 sincos table + keyboard + movement + 8.8 division — follow-on.)
- Boot sequence: SEI; CRTC 256x160 (R1=32,R2=45,R6=20,R7=28,R10 cursor-off,
  R12/R13 -> $5800); page C + JSR span_init($8000); clear $5800 FB; page L0 +
  JSR br_view_setup($4809) + br_init_frame($481B); JSR br_render_frame($4815)
  (pages banks internally); flip CRTC to drawn buffer; (loop or halt).
- Verify on jsbeeb: boot .ssd, screenshot, compare to flat BspRender6502
  framebuffer at the spawn.
doom_loader.asm is the template (bank-copy + CRTC + keyboard all proven there),
but its ZP map ($10+) differs from the standalone ($00+) so the per-frame setup
must be rewritten.
