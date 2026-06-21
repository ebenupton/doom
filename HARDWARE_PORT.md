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
