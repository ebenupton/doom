# Span Clipper Cycle Optimisation

Tracks the 6502 cycle cost of the standalone span clipper subsystem
(`span_clip.asm`) as we incrementally optimise it.

## Benchmark scenes

Two scenes, both `PRESCALE=8`:

- **S1** "opening": position `(1056, -3616)`, angle `64` (spawn East). Simple
  scene, low span count (max 6). Exercises the common fast paths but doesn't
  stress the clipper.
- **S2** "corridor": position `(505, -3268)`, angle `125`. Complex scene,
  max span count 19, ~45 tighten / ~122 has_gap calls — this is where the
  constant-line merge pays off and where the dominance-prelude cost dominates.

Cycles measured by `py65` simulation via the `SpanClip6502` wrapper, summing
`mpu.processorCycles` across every `mark_solid` / `tighten` / `has_gap` /
`is_full` call made during one `packed_render_bsp` of each scene.

## Reproducing

```bash
python3 - <<'EOF'
import os
os.environ['SDL_VIDEODRIVER'] = 'dummy'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
import math, doom_wireframe as dw, fp as fpmod
from wad_packed import spans_init_full
from span_clip_6502 import SpanClip6502
from endpoint_spans import EndpointClipSpans

SCENES = [('S1', 1056, -3616,  64),
          ('S2',  505, -3268, 125)]

sc = SpanClip6502(); sc.init()
oms, otg, ohg, oif = (EndpointClipSpans.mark_solid, EndpointClipSpans.tighten,
                      EndpointClipSpans.has_gap, EndpointClipSpans.is_full)
stats = {}
def reset():
    for k in ('ms_c','ms_n','tg_c','tg_n','hg_c','hg_n','if_c','if_n'): stats[k]=0
def hms(s,l,h):
    oms(s,l,h); sc.mark_solid(l,h); stats['ms_c']+=sc.last_cycles; stats['ms_n']+=1
def htg(s,*a,**k):
    otg(s,*a,**k); sc.tighten(*a[:8]); stats['tg_c']+=sc.last_cycles; stats['tg_n']+=1
def hhg(s,l,h):
    r=ohg(s,l,h); sc.has_gap(l,h); stats['hg_c']+=sc.last_cycles; stats['hg_n']+=1; return r
def hif(s):
    r=oif(s); sc.is_full(); stats['if_c']+=sc.last_cycles; stats['if_n']+=1; return r
EndpointClipSpans.mark_solid = hms
EndpointClipSpans.tighten    = htg
EndpointClipSpans.has_gap    = hhg
EndpointClipSpans.is_full    = hif
pygame.draw.line = lambda *a, **k: None

grand = 0
for name, PX, PY, ANGLE in SCENES:
    reset(); sc.init(); fpmod.mul_reset()
    px88 = int((PX - dw.MAP_CENTER_X) * 256 / dw.PRESCALE)
    py88 = int((PY - dw.MAP_CENTER_Y) * 256 / dw.PRESCALE)
    vz_ps = dw._prescale_height(dw.player_floor(PX, PY) + 41)
    ctx = dw.fp_view_context(px88, py88, dw.fp_sincos(ANGLE))
    cf, sf = math.cos(dw.byte_to_radians(ANGLE)), math.sin(dw.byte_to_radians(ANGLE))
    p_ram = dw._packed_ram_new()
    spans_init_full(p_ram, dw.packed_layout['ram_spans'], dw.FP_RENDER_W, dw.FP_RENDER_H - 1)
    dw.packed_render_bsp(len(dw.nodes)-1, EndpointClipSpans(), ctx, vz_ps,
                         int(PX), int(PY), cf, sf, pygame.Surface((256,160)), p_ram)
    tot = stats['ms_c']+stats['tg_c']+stats['hg_c']+stats['if_c']; grand += tot
    print(f'{name} ({PX},{PY},{ANGLE}):')
    print(f'  mark_solid: {stats["ms_n"]:4} calls, {stats["ms_c"]:7} cycles')
    print(f'  tighten:    {stats["tg_n"]:4} calls, {stats["tg_c"]:7} cycles')
    print(f'  has_gap:    {stats["hg_n"]:4} calls, {stats["hg_c"]:7} cycles')
    print(f'  is_full:    {stats["if_n"]:4} calls, {stats["if_c"]:7} cycles')
    print(f'  TOTAL: {tot}')
print(f'GRAND TOTAL: {grand}')
EOF
```

## History

Before 2026-04-11 the table tracked S1 only; S2 was added when the
constant-line merge optimisation landed.

| Date       | span_clip.bin | S1 mark_solid | S1 tighten | S1 has_gap | S1 is_full | **S1 TOTAL** | Δ      | **S2 TOTAL** | Δ      | Notes |
|------------|--------------:|--------------:|-----------:|-----------:|-----------:|-------------:|-------:|-------------:|-------:|-------|
| 2026-04-10 |       2701 B  | 14714 (19)    | 102580 (12)| 7515 (91)  | 2580 (152) | **127389**   |        |              |        | Baseline after closed-interval refactor + s16 divide / exact crossover correctness fixes. |
| 2026-04-10 |       2576 B  | 14492 (19)    |  98830 (12)| 7515 (91)  | 2580 (152) | **123417**   | −3972  |              |        | Slow path deleted (sic_slow + sic_check_*). Dead code post-`_remap_seg_for_8bit`. Combined negate-and-add-(den-1) into one SBC chain for sif_neg / sis_neg / if_neg / is_neg (saves ~20 cyc per neg-path call). Dropped ex=256 special case in seg_interp_store. PHA/PLA → ZP scratch in `tg_split_one` and the three saves in mark_solid `ms_has_left`. |
| 2026-04-10 |       2578 B  | 14244 (19)    |  77226 (12)| 7690 (91)  | 2580 (152) | **101740**   | −21677 |              |        | Big round (−17.6%). udiv16_8 fast path extended from `div_hi == 0` to `div_hi < div_den` (8 iterations whenever the quotient fits u8 — covers most seg/span interp cases now that the wrapper limits |dy|≤127). Dead writes removed: `zp_i_resh` no longer written by `div_add_y0`/`neg_div_add_y0` (u8 callers don't read it); `zp_i_y1h` removed entirely from the seg interp pipeline (set 4× by tighten but never read). `seg_interp_core` short-circuits when dy=0. `interp_core` reordered to avoid the redundant `STA tmp0`/`LDA tmp0` round-trip. Small-prod fast path added to `interp_floor` and `seg_interp_floor`: when `0 ≤ prod < den` the quotient is 0 and the result is just y0 — saves the divide entirely. Plus `seg_interp_store` got a `prod=0` short-circuit matching `seg_interp_floor`. |
| 2026-04-11 |       2366 B  |  3637 (19)    |  74765 (12)| 5286 (91)  | 2580 (152) | **86268**    | −15472 |              |        | **Lazy line/active-range split.** Spans become 9-byte slots: `(next, xlo, xhi, tl, bl, tr, br, xstart, xend)`. The line definition `(xlo,xhi,tl,bl,tr,br)` is fixed once a span is created; only `(xstart,xend)` move when a span is narrowed. `mark_solid` now does *zero* `interp_store` calls — just byte-shuffling on `xstart`/`xend` plus a copy of the 6 line bytes when a span gets split in two (−10 607 cycles). Tighten's left/right fragment paths similarly preserve the line and only set the new active range (−2 461 cycles in tighten). `has_gap` collapses to a trivial overlap walk against `xstart`/`xend` — no per-span aperture arithmetic (−2 404 cycles). `interp_span` deleted (only mark_solid used it). `tg_overlap_sub` keeps writing dense-anchored sub-interval results (line ≡ active range there), so the cost stays the same. The pool shrinks from 32 to 28 slots to keep all byte offsets ≤ 255. ROM also drops 212 bytes. |
| 2026-04-11 |       2540 B  |  3637 (19)    |  50241 (12)| 5286 (91)  | 2580 (152) | **61744**    | −24524 |              |        | **Dominance-check reuse + old-line preservation in sub-intervals.** The dominance check now uses `interp_store`/`seg_interp_store` so its cached values at `(ox0, ox1)` are directly reusable downstream. The no-crossover case (single sub-interval = full overlap) skips `tg_overlap_sub` entirely and does max/min + aperture + store inline on the already-cached values — saves the 8 interp_store calls that `tg_overlap_sub` used to redo (~−2000 cycles per no-crossover tighten). Crossover sub-intervals in `tg_overlap_sub` now also reuse cached values whenever one of the sub-interval endpoints equals `ox0`/`ox1`, which is always true for the outermost sub-intervals. On top of that, `tg_overlap_sub` gained an "Opt 2" line-preservation check: when max/min shows old wins both top and bot within the sub-interval, copy the old span's line verbatim and just set `xstart`/`xend` to the sub-interval, instead of dense-anchoring. Saves 4 more interps per "old wins" sub-interval. Python was updated to match (dominance check / crossover detection uses `_interp_store`, and the same Opt 2 check in `_tighten_span`). Tighten drops from 6230 → 4186 cycles per call (−33%). |
| 2026-04-11 |       2624 B  |  3637 (19)    |  50184 (12)| 5286 (91)  | 2580 (152) | **61687**    | −57    |              |        | **Dominance-prelude anchor fast path.** When the overlap endpoints `(ox0, ox1)` exactly match a span's LINE anchors `(xlo, xhi)`, the stored `tl/bl/tr/br` bytes *are* already the y values at those endpoints — so all four OLD `interp_store` calls can be replaced by a straight byte copy. A symmetric fast path on the NEW side triggers when `(ox0, ox1)` match the seg anchors `(sx1, sx2)`, copying the s16 seg y values verbatim instead of calling `seg_interp_store` four times. Opening scene only gets 1 NEW fast fire and 0 OLD fast fires across 15 overlaps, so the saving here is a modest 57 cycles — but a 48-frame sweep across 6 locations × 8 angles shows 192/927 OLD hits (20.7%) and 57/927 NEW hits (6.2%), so the check pays off noticeably in broader use. ROM grows 84 bytes. |
| 2026-04-11 |       2690 B  |  3637 (19)    |  51685 (12)| 5286 (91)  | 2580 (152) | **63188**    | +1501  | **226356**   |        | **Constant-line span merge (reinstated) + S2 scene added.** `tg_append_x` now merges a new span X into the current tail Y when both are constant-line spans (`tl==tr` AND `bl==br` on both), their `(tl,bl)` values match, and their active ranges are contiguous. Cheap check: 6 byte compares, fail-fast on the tail's top. Python `_append_merge` matches the asm behaviour. Scene S2 at `(505,-3268,125)` was added as a second benchmark target — it's a complex corridor view with max 19 spans and 45 tighten calls where constant-line fragments dominate (scan: 146/568 adjacent-contiguous pairs per frame are constant-line mergeable vs 0 in S1). S2 drops 280 051 → 226 356 cyc (−53 695, −19.2%): `tighten` 255 812 → 206 794 (−48 k), `has_gap` 14 554 → 11 074, `mark_solid` 5918 → 4721. S1 regresses by 1501 cyc (+2.4%) because its 130 appends all pay the merge check overhead (~11 cyc per miss on fail-fast) and zero merges fire. Also changed `zp_new_tail` sentinel from `$FF` to `0` to save 2 cyc on the "is this the first span?" test in tg_append_x. ROM +66 bytes. |
| 2026-04-11 |       2751 B  |  3637 (19)    |  51493 (12)| 5286 (91)  | 2580 (152) | **62996**    | −192   | **226556**   | +200   | **compute_crossover: restoring divide + inlined u16/u8 fast path.** The old iterative-subtraction loop had unbounded worst case (~49 cyc per quotient unit → up to ~12 500 cyc for a quot=255 crossover). Replaced with two inlined 8-iteration restoring-divide loops: a fast path for `den ≤ 255` (u16 num / u8 den, reusing `zp_div_*` scratch) and a slow path for the rare `den > 255` case (u24/u16, bounded ~360 cyc). Both use the "INC the shift source as the quot accumulator" trick from `udiv16_8`. The fast path fires on 100% of calls in both S1 and S2 (max `den = 7` in S2). S1's single compute_crossover call (quot=8) saves ~160 cyc from not iterating 8× through the full u24 loop; S2's 10 calls with avg `quot = 6` pay a ~20 cyc/call fixed-overhead penalty vs. iterative (since the fast path always runs 8 iterations regardless of quot), for a ~200 cyc net regression in that scene. Break-even on S1+S2 but now robust against pathological scenes that would previously hit the iterative worst case. ROM +61 bytes. |
| 2026-04-11 |       2594 B  |  3637 (19)    |  51394 (12)| 5286 (91)  | 2580 (152) | **62898**    | −98    | **226253**   | −303   | **Deleted `interp_floor`, `interp_ceil`, `seg_interp_floor` + inlined tail helpers.** The three round-up/round-down interp variants were exported via the jump table at `$2012`/`$2015` but never called internally — only the Python `test_interp` unit test reached them. Deleted their bodies (~110 bytes) and the jump-table slots, shifting `interp_store` up to `$2012`. With the floor/ceil functions gone, the u8 tail helpers (`div_add_y0`, `neg_div_add_y0`) and s16 tails (`s16_div_add_y0`, `s16_neg_div_add_y0`) each had only one caller (interp_store / seg_interp_store). Inlined all four, saving the `JMP tail` (3 cyc per hot-path interp call). Python `_interp_ceil` stays — it's used by `draw_clipped`'s `_clip_to_span`, which is a pure-Python path that doesn't hit the 6502. `test_interp` simplified to test only `interp_store`. S1 tighten −99 cyc, S2 tighten −303 cyc, ROM −157 bytes. |
| 2026-04-11 |       2580 B  |  3637 (19)    |  51389 (12)| 5286 (91)  | 2580 (152) | **62902**    | +4     | **226268**   | +15    | **Dead-branch cleanup + single-caller inlines.** Two free-ish wins found by walking function call counts: (1) `udiv16_8`'s `den=0` fallback was dead — all three writers of `zp_div_den` (`interp_core`, `seg_interp_core`, `compute_crossover` fast path) guarantee `den > 0`. Removed the `LDA zp_div_den : BNE dn` check and the `RTS` fallback (−11 bytes). (2) `tg_cc_calc_top` had exactly one caller; inlined its SBC chain into the top-crossover branch of tighten and replaced the tail-call `JMP compute_crossover` with `JSR compute_crossover` at the call site (−3 bytes). `tg_cc_calc_bot` was left alone — its fall-through to `compute_crossover` makes inlining size-neutral. `udiv16_8`'s 16-iter slow path is still needed for `seg_interp_store` (max quot measured at ~1550 when the seg gets extrapolated beyond its post-remap `[sx1, sx2]` at tighten column endpoints). Cycle impact ~noise (+19 across both scenes); main win is ROM −14 bytes. |
| 2026-04-11 |       2573 B  |  3637 (19)    |  45394 (12)| 5286 (91)  | 2580 (152) | **56898**    | −6004  | **205475**   | −20793 | **interp_core / seg_interp_core inlined into their stores + two pre-existing clamping/crossover bugs fixed.** `interp_core` and `seg_interp_core` each had one caller, both "tail-called" `smul8` via fall-through. Inlined each into its store, converting the fall-through to `JSR smul8`; merged the x0==x1 degenerate check with the `SBC` that computes `den` (one instruction does both via `BEQ`); added a `BEQ is_y0` shortcut after the dy SBC to skip `smul8` entirely when `dy == 0` (common for constant-line tops/bots in tighten's dominance prelude). Bugs fixed found while chasing the 697,-3155,54 divergence: (a) tighten's and `tg_overlap_sub`'s s16→u8 clamping blocks missed the `[160,255] / hi=0` case — `nb_l=172, nb_lh=0` was stored as 172 instead of clamped to 159, causing false dominance failures. (b) `tg_cc_{top,bot}`'s `dt != 0` pre-check used a buggy `LDA hi : ORA lo : CMP ot` shortcut that produced false positives when `hi | lo ≡ ot` (e.g. 0x01 \| 0x9E = 0x9F = 159 = ot), causing real crossovers to be skipped at e.g. angle 226. Replaced with a correct `BNE` on high byte + `CMP` on low byte. Also fixed `_remap_seg_for_8bit` to handle lines too steep for any remap (`|dy| > 127` post-remap): if the boundary is consistently off-screen across `[ilo, ihi]`, substitute the clamp constant (0 or 159). S1 tighten −5995, S2 tighten −20793, ROM −7 B. 0 divergences across 1024 frames (16 positions × 64 angles). |
| 2026-04-11 |       2481 B  |  3637 (19)    |  42337 (12)| 5286 (91)  | 2580 (152) | **53840**    | −3058  | **193893**   | −11582 | **Hoist `zp_div_den` setup + new interp interface (A in, A/Y out).** `interp_store` and `seg_interp_store` each get called 4 times per span in the dominance prelude (and again in tg_overlap_sub). Each call was recomputing `den = x1 - x0` (for u8) or `sx2 - sx1` (for seg) even though the result is identical across all 4 calls. Hoisted den computation to the caller: the dominance prelude's `old_slow`/`new_slow` paths and `tg_overlap_sub` now each set `zp_div_den` once before their 4 calls. Also changed the interp interface: x is passed in A (save one `LDA zp_i_x : STA` per call), result is returned in A (save one `LDA zp_i_res : STA` per call); seg_interp_store additionally returns the high byte in Y (save a second `LDA/STA` pair). The u8 `interp_store` x0==x1 degenerate check is also gone from the callee — the anchor fast path guards 1-pixel spans in the dominance prelude, and tg_overlap_sub can't reach a 1-pixel span either (no crossover possible in 0 width). Python test_interp wrapper updated to set `zp_div_den` and `mpu.a` directly. S1 tighten −3057, S2 tighten −11582, ROM −92 B. |

| 2026-04-12 |       2510 B  |  3631 (19)    |  38806 (12)| 7744 (127) | 2512 (148) | **52693**    | −3537  | **180487**   | −16715 | **udiv16_8 skip loop for leading zero quotient bits.** The 8-iteration restoring division loop now pre-scans: shift rem:div_hi left one bit at a time, checking rem vs den. Each skip iteration (~19 cyc) replaces a wasted main-loop iteration (~33 cyc for a trial-subtract-that-fails), saving ~14 cyc per skipped bit. When the quotient is small (common for tighten interpolations near span edges), 3-4 leading iterations produce zero bits and are skipped. Falls through to the main loop once the first productive bit is found. Quotient=0 case returns immediately without entering the main loop at all. Note: S1/S2 call counts differ from previous row due to BSP traversal changes (round-to-nearest prescaling, near-child bbox check, frustum reject) — the clipper code is unchanged except for this udiv16_8 optimisation. S1 tighten −3531, S2 tighten −16708. ROM +29 B. |

| 2026-04-12 |       2573 B  |  3631 (19)    |  37875 (12)| 7744 (127) | 2512 (148) | **51790**    | −903   | **176325**   | −4162  | **Unrolled skip loop.** The 8-iteration skip pre-scan is unrolled: 8 copies of `ASL div_hi : ROL A : BCS commit : CMP den : BCS commit : DEX` eliminate the `BNE dskip` branch (3 cyc per skipped iter). Last copy omits the final DEX since quotient=0 falls through to RTS. S1 tighten −931, S2 tighten −4215. ROM +63 B. |
| 2026-04-12 |       2573 B  |  3659 (19)    |  37671 (12)| 7744 (127) | 2512 (148) | **51586**    | −204   | **175393**   | −932   | **umul8: replace PHP/PLP with CPX for carry detection.** The quarter-square multiply saved/restored the carry flag from the `ADC zp_mul_b` sum via PHP (3 cyc) + PLP (4 cyc) = 7 cycles. Replaced with `CPX zp_tmp0` (3 cyc) after computing |a-b|: if `(a+b) & 0xFF < a`, the sum overflowed. Net saving: 4 cycles per umul8 call. S1 tighten −204, S2 tighten −932. ROM unchanged. |
| 2026-04-12 |       2576 B  |  3659 (19)    |  37671 (12)| 6680 (127) | 2656 (148) | **50666**    | −920   | **172716**   | −2677  | **has_gap: check xend before xstart.** The inner loop now checks `POOL_XEND,X >= ilo` first, skipping spans before the query range in one comparison instead of two. Since the list is sorted by xstart, once `xend >= ilo` is found, a single `xstart <= ihi` check determines overlap vs. past. Saves ~11 cycles per "before" span iteration (the common case). is_full regresses +1 cyc/call from code shift across a page boundary. S1 has_gap −1064, S2 has_gap −2891. ROM +3 B. |
| 2026-04-12 |       2576 B  |  3659 (19)    |  37671 (12)| 6656 (127) | 2376 (148) | **50362**    | −304   | **172290**   | −426   | **is_full: swap branch sense to avoid page-crossing BNE.** The `BNE snf` in is_full was crossing from page $22 to $23 on every call (+1 cyc). Replaced with `BEQ sif_yes` so the common (non-full) path falls through without crossing a page. Rare full case pays the +1 page-cross penalty instead. Also gained ~2 cyc/call from avoiding the page-crossing path. S1 is_full −280, S2 is_full −414. ROM unchanged. |
| 2026-04-12 |       2578 B  |  3659 (19)    |  37607 (12)| 6656 (127) | 2376 (148) | **50298**    | −64    | **172193**   | −97    | **Division loop: CMP before SBC to save SEC on no-commit iterations.** The restoring division main loop and compute_crossover fast_loop both used `SEC : SBC den : BCC skip` for the trial subtract, paying 2 cycles for SEC on every iteration even when the subtract fails. Replaced with `CMP den : BCC skip : SBC den` — the CMP doesn't modify A, and on the commit path carry is already set from the successful CMP. Saves 2 cycles per no-commit iteration, costs 1 extra cycle per commit iteration. Net win since most quotient bits are 0. S1 tighten −64, S2 tighten −97. ROM +2 B. |
| 2026-04-12 |       2605 B  |  3659 (19)    |  35536 (12)| 6656 (127) | 2376 (148) | **48227**    | −2071  | **167462**   | −4731  | **Dominance prelude: constant-line OLD span fast path.** When the OLD span is constant-line (`tl==tr` AND `bl==br`), the interp values at any X are just `tl` and `bl` — no interpolation needed. Added a check after the anchor fast path: 2 byte-compares (tl vs tr, bl vs br), and on match, copy tl/bl directly to all 4 output slots, skipping 4 `interp_store` calls. Fires on all constant-line spans that don't also trigger the anchor fast path (i.e. when the overlap doesn't exactly cover [xlo, xhi]). In S2, constant-line spans are the majority. S1 tighten −2071, S2 tighten −4731. ROM +27 B. |
| 2026-04-12 |       2656 B  |  3659 (19)    |  34650 (12)| 6656 (127) | 2376 (148) | **47341**    | −886   | **166965**   | −497   | **Dominance prelude: constant-line NEW seg fast path.** Symmetric to the OLD constant-line check. When the NEW seg has `yt1==yt2` AND `yb1==yb2` (s16 equality, 4 byte compares), copy the anchor s16 values directly to all 8 output slots, skipping 4 `seg_interp_store` calls. Fires when the seg boundary is flat (parallel to the view plane), common for horizontal wall sections. S1 tighten −886, S2 tighten −497. ROM +51 B. |
| 2026-04-13 |       2734 B  |  3659 (19)    |  34317 (12)| 6656 (127) | 2376 (148) | **47008**    | −333   | **166631**   | −334   | **tg_overlap_sub: constant-line fast paths for OLD and NEW.** Applied the same constant-line checks to the crossover sub-interval processing. When OLD span has tl==tr/bl==br or NEW seg has yt1==yt2/yb1==yb2, skip the 4 interp calls and copy values directly. Less impactful than the dominance prelude paths because crossover splits are rarer. S1 tighten −333, S2 tighten −334. ROM +78 B. |
| 2026-04-13 |       2795 B  |  3659 (19)    |  34019 (12)| 6656 (127) | 2376 (148) | **46710**    | −298   | **166021**   | −610   | **Crossover detection: ORA fast path for hi==0 case.** When both `nt_lh/nt_rh` (or `nb_lh/nb_rh`) are 0 — the common case for on-screen seg values — the sign-of-difference computation skips the individual per-byte BMI/BNE checks and does two simple `CMP` + `ROL` + `EOR`. Saves ~12 cycles per boundary (top/bot) per overlapping span in the common case. S1 tighten −298, S2 tighten −610. ROM +61 B. |
| 2026-04-13 |       2784 B  |  3699 (19)    |  33695 (12)| 6656 (127) | 2372 (148) | **46422**    | −288   | **164800**   | −1221  | **smul8: avoid double negate via unsigned interpretation.** When A < 0, the old smul8 negated the input, called umul8, then negated the 16-bit output (24 extra cycles). New approach: call umul8 with the raw negative byte (unsigned interpretation = A+256), then correct with `prod_hi -= mul_b`. This exploits `A_s8 * B = A_u8 * B - 256*B`. Saves 13 cycles per negative-dy multiply. S1 tighten −324, S2 tighten −1255. ROM −11 B. |

| 2026-04-13 |       2821 B  |  3699 (19)    |  33262 (12)| 6656 (127) | 2372 (148) | **45989**    | −433   | **164168**   | −632   | **Clamp fast path: skip clamping when all s16 values already in [0,159].** Added a quick check before the 4-block clamping: ORA all 4 hi bytes; if all zero, check each lo byte < 160. When all pass (the common case for on-screen segs), skip clamping entirely. Saves ~27 cycles per overlapping span vs the full 4-block clamp. S1 tighten −433, S2 tighten −632. ROM +37 B. |

| 2026-04-13 |       2858 B  |  3699 (19)    |  33208 (12)| 6656 (127) | 2372 (148) | **45935**    | −54    | **164156**   | −12    | **tg_overlap_sub: same clamp fast path.** Applied the identical ORA+CMP skip check to the crossover sub-interval clamping. Marginal gain since crossover splits are less frequent. S1 tighten −54, S2 tighten −12. ROM +37 B. |

| 2026-04-13 |       2842 B  |  3699 (19)    |  32908 (12)| 6656 (127) | 2372 (148) | **45635**    | −300   | **162563**   | −1593  | **Eliminate zp_save0 in tighten walk loop.** Store POOL_NEXT directly to `zp_old_cur` at the top of `tg_process`, instead of going through `zp_save0` as an intermediary. Since no subroutine during tighten processing modifies `zp_old_cur`, this eliminates 4 `LDA zp_save0 : STA zp_old_cur` epilogues (6 cycles each), saving ~6 cyc per span visited in the walk loop. S1 tighten −300, S2 tighten −1593. ROM −16 B. |

| 2026-04-13 |       2836 B  |  3699 (19)    |  32854 (12)| 6656 (127) | 2372 (148) | **45581**    | −54    | **162326**   | −237   | **Overlap computation: avoid redundant POOL_XSTART reload.** The `ox0 = max(xstart, ilo)` code was reloading POOL_XSTART,X after BCS even though CMP doesn't modify A. Removed the reload and the JMP by restructuring: `LDA XSTART : CMP ilo : BCS set : LDA ilo : .set STA ox0`. Saves 3-4 cycles per overlapping span. S1 tighten −54, S2 tighten −237. ROM −6 B. |

| 2026-04-13 |       2961 B  |  3699 (19)    |  30945 (12)| 6392 (127) | 2372 (148) | **43408**    | −2173  | **129533**   | −32793 | **New-dominance BB fast path + Path A/B bugfix.** Symmetric to the existing old-dom BB check: when all seg values are on-screen [0,159] and `max(tl,tr) <= min(yt1,yt2)` AND `min(bl,br) >= max(yb1,yb2)`, new dominates everywhere. Skip OLD interpolation + crossover detection; set dummy old values (0/159) so the no-crossover inline path produces new boundary values. Also fixed Path A/B shared `tg_bb_check_bot` bug where Path A's neg-yt failure path could incorrectly fall through to new-dom check with off-screen yt values. Path A bot check now inlined. S1 tighten −1909, S2 tighten −2965. ROM +125 B. |

| 2026-04-13 |       2966 B  |  3699 (19)    |  30990 (12)| 6392 (127) | 2372 (148) | **43453**    | +45    | **129001**   | −532   | **Skip top crossover detection when yt is negative.** When both yt hi bytes have bit 7 set (Path A neg yt), old top auto-dominates → dt always positive → no top crossover. Jump directly to `tg_cc_no_top`, saving ~50 cycles of slow-path sign detection per firing. Fires on 23/35 full-interp overlaps in S2. S1 tighten +45, S2 tighten −532. ROM +5 B. |

| 2026-04-13 |       2990 B  |  3699 (19)    |  31010 (12)| 6392 (127) | 2372 (148) | **43473**    | +20    | **128360**   | −641   | **Fast-path clamping for neg-yt overlaps.** When yt is negative, nt values always clamp to 0 — write immediately, then only clamp bot values (sharing the existing slow-path code via `tg_clamp_nb_entry`). S1 tighten +20, S2 tighten −641. ROM +24 B. |

| 2026-04-13 |       2988 B  |  3659 (19)    |  30396 (12)| 6392 (127) | 2372 (148) | **42859**    | −614   | **125275**   | −3085  | **Offset-zero shortcut in interp_store and seg_interp_store.** When offset (x−x0) is 0, the result is y0 regardless of dy. Check `BEQ` immediately after the SBC that computes offset, before the STA to mul_b, skipping dy computation, smul8, and divide. S1 tighten −614, S2 tighten −3084. ROM −2 B. |

| 2026-04-13 |       2995 B  |  3631 (19)    |  29187 (12)| 6452 (127) | 2372 (148) | **41608**    | −1251  | **121922**   | −3353  | **Offset-max shortcut in u8 interp_store.** When offset equals div_den (x at right anchor), result is y1. Check `CMP zp_div_den : BEQ is_y1` after offset-zero, returning y1 directly. S1 tighten −1209, S2 tighten −3267. ROM +7 B. |

| 2026-04-13 |       3031 B  |  3631 (19)    |  29430 (12)| 6452 (127) | 2372 (148) | **41885**    | +277   | **112893**   | −9029  | **Offset-max shortcut in s16 seg_interp_store.** Same check as u8 version, returning y1 lo/hi from zp_i_y1/zp_i_y1h. The 6 caller sites now store the y1 hi byte (+6 LDA/STA pairs). S1 tighten +243, S2 tighten −9082. ROM +36 B. |

| 2026-04-13 |       3043 B  |  3631 (19)    |  28475 (12)| 6452 (127) | 2372 (148) | **40930**    | −955   | **103142**   | −9751  | **Post-seg bulk-link in tighten walk.** When xstart > ihi, all remaining spans are past the seg. Append the first via tg_append_x (merge check), then bulk-link the rest by writing one POOL_NEXT pointer. Saves ~40 cyc/span for all post-seg spans. S1 tighten −955, S2 tighten −9751. ROM +12 B. |

| 2026-04-13 |       3325 B  |  3631 (19)    |  27922 (12)| 6452 (127) | 2372 (148) | **40377**    | −553   | **98903**    | −4239  | **Pre-seg bulk-link in tighten walk.** Pre-scan old list at tighten start to find first span with xend >= ilo. All prior spans are bulk-linked as new list head (~14 cyc/span vs ~53). If ALL spans are pre-seg, link entire old list and return immediately. S1 tighten −553, S2 tighten −4239. ROM +282 B. |

| 2026-04-14 |       3372 B  |  3519 (19)    |  26419 (12)| 5359 (127) | 2372 (148) | **37669**    | −2708  | **93409**    | −5494  | **Micro-optimisation batch.** (1) Reversed CMP operands in dominance checks and range comparisons across has_gap, mark_solid, and tighten — eliminates redundant BEQ+BCS/BCC pairs, saving 2 cyc per check. Applied to 10 sites. (2) udiv16_8 fast-path main loop keeps remainder in A register: ROL A (2 cyc) replaces ROL zp (5) + LDA zp (3), STA after SBC eliminated. Saves 6-9 cyc per main-loop iteration. Same optimisation applied to compute_crossover fast path. (3) Removed dead `prod == 0` check from both interp_store and seg_interp_store: when offset > 0 AND |dy| > 0 (guaranteed by prior BEQ checks), quarter-square multiply always produces nonzero result. Saves 9 cyc per full-path interp call. (4) Per-copy commit handlers in unrolled skip loop: each of the 8 copies branches to its own handler (dsc7..dsc0) that hardcodes the remaining count via LDX #N, eliminating the 2-cyc DEX from every non-commit skip iteration. (5) Moved interp_store is_y0/is_y1 before entry point to avoid page-crossing BEQ branches. S1 total −2708, S2 total −5494. ROM +47 B. |

| 2026-04-14 |       2961 B  |  3532 (19)    |  26039 (12)| 5531 (127) | 2421 (148) | **37523**    | −146   | **112434**   | +19025 | **Reapplied optimisation batch from clean baseline (ed6ea91), wide-tested.** Starting from the commit b0d059f baseline (S1=43858, S2=146244, GRAND=190102), reapplied optimisations one at a time with wide-test coverage (9 positions x 128 angles = 1152 frames, <= 2 failures throughout). Changes applied: (1) has_gap coherence cache at $D0 (−2580 cyc). (2) Reversed CMP/BEQ elimination at 10 sites in has_gap, mark_solid, tighten (−1647). (3) udiv16_8 per-copy commit handlers: each skip copy branches to own `LDX #N` (−2082). (4) udiv16_8 + compute_crossover A-register main loop: remainder in A instead of zp_div_rem (−1122). (5) Offset-zero shortcut in interp_store + seg_interp_store (−13939). (6) Offset-max shortcut in u8 interp_store (included in #5). (7) Dead prod==0 check removal: exhaustively verified |dy|*offset nonzero (−1261). (8) Post-seg bulk-link in tighten walk (−12901). (9) Pre-seg fast-link: skip merge check for pre-seg spans (−3591). (10) Dead STA zp_div_rem removal (−429). (11) umul8 restructure: compute |diff| before sum, use ADC carry (−479). (12) Merged redundant LDA #0 in tg_go (−114). Group 2 neg-yt crossover fast paths investigated but reverted (net +132 on tested scenes). Failed dominance fast-link attempt reverted (merge check required for correctness). Grand total: 190102 -> 149957 (−40145, −21.1%). ROM −411 B vs previous entry. NOTE: S2 total is higher than previous row because the previous row included optimisations (new-dom BB, neg-yt skip, neg-yt clamp, seg offset-max via zp_i_y1h) that were not reapplied here due to failing wide-test or net-cost. |

| 2026-04-14 |       2961 B  |  3554 (19)    |  25647 (12)| 5531 (127) | 2372 (148) | **37104**    | −419   | **111023**   | −1411  | **Micro-optimisation batch #2.** (1) BB top check: reorder to compute max(yt1,yt2) into zp_tmp0 first, then min(tl,tr) into A, enabling single `CMP+BCS` instead of `CMP+BEQ+BCC` (−26 S1, −66 S2). (2) Pre-seg fast-link: replace `LDY zp_new_tail` with `TAY` since A already holds the value from the preceding LDA (−6 S1, −54 S2). (3) Defer `zp_final_ox1` save into `tg_has_splits` — the no-crossover path (common) skips the dead store entirely (−72 S1, −234 S2). (4) Defer `POOL_NEXT,X = 0` write in `tg_append_x`: merge path doesn't need it, first-span path reuses A=0 from preceding LDA, link path writes it just before linking (−4 S1, −71 S2). (5) Remove redundant `LDA zp_ihi` in mark_solid no-left-fragment path: CMP doesn't modify A (−27 S1, −30 S2). (6) Branch-based crossover detection: replace ROL+STA+ROL+EOR sign-bit chain with direct BCS/BCC branching on the CMP carry flag for both top and bot fast paths — saves ~12 cyc per boundary per overlap in the common no-crossover case (−284 S1, −956 S2). S1 total −419, S2 total −1411. ROM unchanged. |

| 2026-04-14 |       2959 B  |  3546 (19)    |  25639 (12)| 5531 (127) | 2372 (148) | **37096**    | −8     | **110959**   | −64    | **Remove redundant BEQ in ox1 min computation.** `min(xend, ihi)` used `BCC : BEQ` (unsigned ≤ check). Since the BEQ case (xend == ihi) loads ihi which equals xend — same result either way — the BEQ is dead. Removing it saves 2 cyc per overlap where xend ≥ ihi. S1 tighten −8, S2 tighten −64. ROM −2 B. |

| 2026-04-14 |       2953 B  |  3546 (19)    |  25621 (12)| 5531 (127) | 2372 (148) | **37078**    | −18    | **110893**   | −97    | **Left+right frag: pre-load old span into Y, skip reload after alloc.** Applied to both left and right fragment paths: load old span offset into Y before the xstart/xend check; since alloc_span preserves Y, the 6-byte line copy can use Y directly without `LDY zp_save1` reload. Saves 3 cyc per fragment allocation. S1 tighten −18, S2 tighten −97. ROM −6 B. |

| 2026-04-14 |       2924 B  |  3411 (19)    |  25578 (12)| 5369 (127) | 2372 (148) | **36730**    | −348   | **110345**   | −548   | **mark_solid restructuring + 12× JMP→branch + 2× BIT hack.** (1) Moved `msl` down before `ms_has_left`: `ms_shrink` falls through to `msl`, `ms_free` unlink paths use short BNE, middle-split and left_only tails convert `JMP msl` to BNE. Inverted `ms_overlap` BCS/BCC so "fully covered" falls through to `ms_free`. (2) Crossover slow path (top+bot): 8× `JMP` → BCC/BNE. (3) Crossover fast path (bot): 2× `JMP tg_cc_b_check_dt` → BCS/BCC. (4) Removed `tg_cc_t_has_cx` trampoline — branch directly to `tg_cc_t_check_dt` (in range at +63/+54). (5) BIT abs hack at `tg_cc_no_top` and `tg_cc_no_bot`: `EQUB $2C` skips `LDA #0`, shared `STA zp_cx_{top,bot}` serves both paths (−4 B, −2 cyc on has-crossover path). Total: 14 JMPs eliminated. S1 mark_solid −135, S2 mark_solid −143. ROM −29 B. |

| 2026-04-14 |       2928 B  |  3393 (19)    |  25586 (12)| 5372 (127) | 2372 (148) | **36723**    | −7     | **110233**   | −112   | **mark_solid X/Y ping-pong scan loop.** Applied the has_gap ping-pong pattern to `msl`: X and Y iterations alternate, eliminating the `TAX` (2 cyc) on every skip. When the Y iteration finds an overlap, `ms_chk_after_y` transfers via `TYA:TAX` (4 cyc) before falling through to the X-based overlap code — the transfer cost is paid only on the rare overlap path. Middle-split and left_only re-entry points now branch to `msl_y` (closer, avoids out-of-range backward branch). S1 mark_solid −18, S2 mark_solid −106. ROM +15 B. |

| 2026-04-14 |       3069 B  |  3334 (19)    |  26348 (12)| 5400 (127) | 2372 (148) | **37454**    | +731   | **99516**    | −10717 | **Reattempted 4 parked optimisations + new-dom BB guard fix.** (1) **New-dom BB fast path:** after old-dom BB fails (all seg hi=0), check if new seg dominates old span everywhere. If `max(yt1,yt2) ≤ min(tl,tr)` AND `min(yb1,yb2) ≥ max(bl,br)`, set dummy old (0/159) and jump to `old_done`, skipping old interp. (2) **Skip top cx when nt<0:** at `tg_cc_t_slow`, `AND` the two nt hi bytes; if both negative, no top crossover → jump to `tg_cc_no_top` (−790 S2). (3) **Fast neg-yt clamp:** at `tg_clamp_slow`, if both nt hi bytes negative, write nt=0 immediately, skip to bot-only clamping (−66 S2). (4) **seg_interp offset-max:** after offset-zero check, `CMP zp_div_den : BEQ sis_y1` returns y1 lo/hi directly, skipping smul8+udiv16_8. Required `STA zp_i_y1h` at 4 caller sites. Dominant win: −9618 S2 alone. Previously parked due to wide-test mismatches caused by the remap-range overflow (fixed earlier this session by clamping [ilo,ihi] to remapped [sx1,sx2]). **Two bugs found in new-dom BB:** (a) when the overlap is a strict subset of the span (xstart < ilo), `max(tl,tr)` includes values outside the overlap — fixed by guarding with `xstart >= ilo AND xend <= ihi`. (b) When old and new values are equal at the boundary, new-dom fired but Python considers this old-dom (keeping span unchanged). Fixed by using strict inequality (`BCC:BEQ` instead of `BCC` alone) in both top and bot checks. S1 regresses +731 from overhead. ROM +141 B. |

| 2026-04-14 |       3047 B  |  3334 (19)    |  26064 (12)| 5606 (127) | 2372 (148) | **37376**    | −78    | **99180**    | −336   | **Grind agent micro-optimisations.** 8 changes: (1) cx_from_quot TAY/CPY/TYA → CMP. (2) ms_chk_after: invert BCS+RTS to BCC to share RTS. (3) tg_bulk_has_tail: direct LDY. (4) 8× BIT trick in clamp. (5) 4× BIT trick in crossover sign. (6) Remove 3 stale alignment pads. (7) Pre-seg fast link: direct LDY. (8) Optimal alignment pad tuning. Most savings from page-alignment shifts, not the instruction changes themselves. S1 −78, S2 −336. ROM −22 B. |

| 2026-04-14 |       3093 B  |  3341 (19)    |  26186 (12)| 5614 (127) | 2372 (148) | **37513**    | +137   | **92592**    | −6588  | **Extended BB old-dom for off-screen top.** When both yt hi-bytes are negative (seg top above screen) AND both yb hi-bytes are zero (bot on-screen), the top dominance check trivially passes (old top ≥ 0 always beats negative new top). Only the bot check runs. Restructured the BB guard to check "both yt negative" FIRST via `AND+BMI`, before the 4-way ORA for all-zero. Fires heavily in S2 where near-wall segs have off-screen tops (~23/45 tighten calls). Also investigated seg value caching across contiguous spans — reverted because tighten's fragment creation introduces off-by-one gaps (ox0_next = ox1_current + 1), preventing cache hits. S1 regresses +137 from reordered guard overhead. S2 −6588 (−6.6%). ROM +46 B. |

Per-call averages (S1): `mark_solid` 176, `tighten` 2182, `has_gap` 44, `is_full` 16.
Per-call averages (S2): `mark_solid` 208, `tighten` 1729, `has_gap`  49, `is_full` 16.

From clean baseline (GRAND 190 102 → 130 105): **−59 997 cyc, −31.6%**.
Cumulative vs original baseline (S1 127 389 → 37 513): **−89 876 cyc, −70.6%**.
ROM size: 2701 → 3093 bytes, **+392 bytes**.

## Notes on this round

- **Constant-line merge is scene-shaped.** The earlier "exact line params
  match" merge attempt found 0 merges in both S1 and a 48-frame sweep
  because tighten preserves lines via xlo/xhi bytes that get stamped at
  span creation time; two adjacent fragments of the same original span
  always share their `(xlo,xhi,tl,bl,tr,br)` tuple exactly, but they're
  never contiguous (there's always a seg between them that split them).
  Constant-line pairs are different: when a seg produces `dy=0` on both
  top and bot (which happens a lot for seg segments running parallel to
  the view plane), the resulting fragments are stamped with arbitrary
  `xlo/xhi` values but `tl==tr`, `bl==br`, so two constant-line fragments
  with matching `(tl, bl)` are effectively the same line regardless of
  anchor positions. In S2, 146/568 contiguous adjacent pairs per frame
  are constant-line mergeable; in S1 the count is 0. The check (6 byte
  compares with fail-fast on the tail's top) costs ~11 cyc per S1 append
  × 130 appends = +1500 cyc slowdown, but saves ~53 k cyc in S2.
- **Dominance-prelude anchor fast path.** Dominance prelude is the hottest
  block in `tighten`: across 927 overlaps in a 48-frame sweep, 35% end in
  "old dominates" (8 interps then keep), 58% in "no-crossover" (8 interps
  then inline max/min), 7% in split paths (8 interps plus `tg_overlap_sub`).
  Those 8 interps per overlap swamp everything else. When `ox0==xlo` and
  `ox1==xhi` the stored `tl/bl/tr/br` bytes are already the y values at
  those endpoints — no interp needed. Same holds for the NEW side when
  `ox0==sx1` and `ox1==sx2`. Python reference and asm both gained the
  check. Opening scene barely exercises this (15 overlaps → 1 NEW hit)
  but the 48-frame sweep exercises it ~27% of the time.
- **udiv16_8 fast path extended.** Was only triggered for `div_hi == 0`
  (prod fits u8). Now triggers for `div_hi < div_den`, which corresponds to
  "the quotient fits u8". The setup is the same as the existing fast path
  except `div_rem` starts as `prod_hi` instead of 0 — equivalent to skipping
  the first 8 of 16 iterations of the slow path, since with `prod_hi < den`
  no commits would have fired in those first 8 iterations. Single biggest
  win of the round (~7000 cycles).
- **Dead writes removed.** `zp_i_resh` was being set to 0 by every u8
  interp tail (`div_add_y0`, `neg_div_add_y0`) even though no caller of
  `interp_floor`/`interp_store`/`interp_ceil` ever reads it. `zp_i_y1h` was
  worse: written 4× per tighten by the seg-interp setup blocks but never
  read by *anything* — the seg interp pipeline only needs the low byte of
  y1 (it computes dy as a low-byte SBC). The high byte of y0 IS still
  needed (for the s16 add at the tail).
- **`seg_interp_core` short-circuits when dy=0.** `LDA y1 : SEC : SBC y0`
  followed by `BNE sic_mul`; if A is zero we just store `prod = 0` and
  return without going through smul8.
- **`interp_core` cleaned up.** The old version did
  `LDA y1 : SBC y0 : STA tmp0 : LDA x : SBC x0 : STA mul_b : LDA tmp0`
  to get dy back into A before falling through to smul8. Reordered to
  compute offset first, then dy directly into A — saves the tmp0 round-trip
  (6 cycles per call).
- **Small-prod fast path** added to `interp_floor` and `seg_interp_floor`.
  When `0 ≤ prod < den` the quotient of the floor division is exactly 0
  and the result is just `y0` — no divide needed. Replaces the existing
  `prod = 0` short-circuit (which only handled the prod=0 case) with a
  combined check that handles `prod = 0` AND any other small positive
  prod. The negative case still goes through the divide because the
  short-circuit value would be `y0 - 1`, not `y0`.
- Also added a `prod = 0` short-circuit to `seg_interp_store` (matches
  `seg_interp_floor`).

This round delivers the biggest single win the user asked about: when
values are small enough that the quotient fits u8, the divide drops from
16 iterations to 8 — a near-halving of the dominant cost. Combined with
the small-prod fast path that skips the divide entirely when `prod < den`,
the seg interp pipeline is much closer to "average case ≈ best case".

## Micro-optimisation round (profiler-guided)

**Starting point**: S1=37,078 S2=110,893 Grand=147,971 ROM=2,953 bytes

Per-instruction profiling (py65 cycle counting per PC) identified hotspots
and page-crossing branch penalties. Changes applied:

1. **has_gap cache-hit page-crossing elimination** (−371 cyc): The cache-hit
   BCS from page $22 to $23 (hg_yes label) was inverted to BCC hg_no_cache
   with inline `LDA #1 : RTS`, keeping the taken branch on the same page.
   Removed the now-unreferenced `hg_yes` label (−3 bytes ROM).

2. **Bounding-box BCS+JMP → BCC** (−46 cyc): In the tighten bounding-box
   precheck, `CMP tmp0 : BCS top_ok` followed by `JMP bb_skip` was replaced
   with `CMP tmp0 : BCC bb_skip` (direct branch on failure). Saves 1 cycle
   when the check passes and 2 cycles when it fails, plus 3 bytes ROM.

3. **mark_solid BEQ+JMP → BNE+RTS** (−113 cyc): The no-left-fragment loop
   continuation `TAX : BEQ ms_rts1 : JMP msl` / `ms_rts1 RTS` was rewritten
   as `TAX : BNE msl : RTS` since msl is within branch range. Saves 2 cycles
   per continuation (14 hits) and 1 byte ROM.

4. **tg_overlap_sub tail-call JSR→JMP** (−36 cyc): Two `JSR tg_append_x` +
   `RTS` pairs at the end of tg_overlap_sub were converted to `JMP tg_append_x`,
   eliminating 3 cycles per call (JSR overhead avoided since tg_append_x's RTS
   returns directly to the caller).

**Final**: S1=36,868 S2=110,537 Grand=**147,405** ROM=2,949 bytes
Delta: **−566 cycles (−0.38%)**, −4 bytes ROM

## Carry propagation round

**Starting point**: S1=36,868 S2=110,537 Grand=**147,405** ROM=2,949 bytes

Systematic analysis of every SEC/CLC instruction to find cases where the
carry flag is already in the required state from a prior instruction.
Key constraint: any code-size change shifts downstream code, potentially
introducing page-crossing branch penalties that wipe out the savings.
Each byte saved requires a dead-code padding byte at a carefully chosen
location to preserve alignment.

1. **umul8 overflow path: redundant SEC** (−60 cyc): After `BCS uo`,
   carry is guaranteed set. The SEC before the first SBC in the overflow
   path is redundant. Saves 2 cycles per overflow-path multiply. 1-byte
   pad after umul8 RTS preserves alignment.

2. **udiv16_8 dl_over: redundant SEC** (unmeasurable): Same pattern --
   `BCS dl_over` guarantees carry set. SEC before SBC is redundant.
   Overflow path is too rare to measure but correctness verified.

3. **compute_crossover fast_over: redundant SEC** (unmeasurable): Same
   pattern for the crossover divider's overflow path.

4. **mark_solid shrink path: redundant CLC** (−38 cyc): After `BCS
   ms_jmp_free` falls through, carry is guaranteed clear. The CLC before
   `ADC #1` (computing ihi+1 for new xstart) is redundant.

5. **mark_solid middle-split: CLC for ADC #1** (−2 cyc): Same carry-clear
   propagation from BCS fall-through through alloc_span (which preserves
   carry) and LDA/STA copy chain.

6. **mark_solid middle-split: SEC:SBC #1 → SBC #0** (−2 cyc): Carry is
   clear from same propagation chain. With C=0, `SBC #0` computes
   `A - 0 - 1 = A - 1`, equivalent to `SEC : SBC #1`. Saves SEC (1 byte,
   2 cycles).

7. **tighten left frag: SEC:SBC #1 → SBC #0** (−2 cyc): BCS tg_no_left
   falling through guarantees C=0. Same trick as #6.

8. **tighten right frag: redundant CLC** (tiny): BCS tg_no_right falling
   through guarantees C=0.

**Attempted but reverted:**
- seg_interp_store SEC before dy SBC: carry analysis was wrong -- when
  sx1 is negative (post-remap), the 8-bit low byte of sx1 > ox0, causing
  a borrow that clears carry. SEC is needed.
- tg_append_x CLC→ADC#0: net regression due to has_gap page alignment
  shift (+22 cycles from page-crossing penalties).
- 4x JMP→BNE in slow crossover sign detection: 4-byte pad at any location
  shifts too much code, causing page-crossing regressions that exceed the
  savings.

**Final**: S1=36,822 S2=110,479 Grand=**147,301** ROM=2,949 bytes
Delta from micro-opt round: **−104 cycles (−0.07%)**

## Page-alignment round

**Starting point**: S1=36,822 S2=110,479 Grand=**147,301** ROM=2,949 bytes

Comprehensive SEC/CLC audit and JMP audit found all remaining SEC/CLC
instructions are needed (carry state genuinely unknown or wrong at each
site). JMP audit found most are either out of branch range or lack a
known flag state for conditional replacement.

The main win came from page-crossing branch analysis. Enumerated all 33
page-crossing conditional branches in the binary and tested padding
adjustments at code section boundaries.

1. **3-byte pad before mark_solid + reduce post-mark_solid pad 5→2**
   (−81 cyc): Added 3 bytes of padding before `span_mark_solid` to push
   the `msl` loop start past `$2200`, fixing the `BCS ms_chk_after`
   page crossing ($21FD→$2208 → $2200→$220B, same page $22). Reduced
   the 5-byte pad after mark_solid to 2 bytes (net 0 byte change) to
   avoid introducing a has_gap page crossing from the +3 shift.
   mark_solid −148 S1, −47 S2. ROM unchanged.

2. **tg_overlap_sub clamp JMP→BCC** (0 cyc): Converted `JMP
   tos_clamp_done` to `BCC tos_clamp_done` with 1-byte compensating
   pad. Carry is guaranteed clear from preceding `BCS tos_clamp_slow`
   fall-through. Cycle-neutral (BCC same page = 3 cyc = JMP), code
   cleanup only.

**Attempted but not applied:**
- Moving `span_init` (61 bytes) after the hot code would fix all 17
  udiv16_8 skip-loop BCS crossings, but the main loop `dl` straddles
  the $2100 page boundary, adding 3 crossings in the hottest inner loop
  (4-8 hits per divide). Padding to push dl to $2100 causes
  dskip_commit BNE dl to cross pages. Net: zero improvement for
  udiv16_8, plus unpredictable effects on downstream code.
- Pad=8/11/25 before mark_solid: fixes more mark_solid crossings but
  introduces 4+ has_gap crossings ($22E2 BEQ, $22E9 BCS, $22EE BEQ,
  $22FA BNE) that fire on every has_gap call (~127/scene), outweighing
  the gains.
- Removing line 193/276 pads (umul8, udiv16_8): both protect the
  mark_solid BCS fix; removing either un-fixes $2200 BCS→$220B.

**SEC/CLC audit results:** All 26 SEC and 10 CLC instructions verified
needed. One SEC in compute_crossover slow path (line 1251) is provably
redundant (carry set from all entry paths: BCS, BCC-not-taken+BNE, and
CMP-fall-through), but the slow path fires 0 times in both benchmark
scenes, making the saving unmeasurable.

**JMP audit results:** 48 JMPs total (7 jump table, 41 code). 30 are
within branch range. Of those, most either lack a known flag state after
the preceding instruction (STX/STA don't set flags on 6502) or would
cross pages if converted. The slow-path crossover sign-detection JMPs
(8 total, all within range) were previously attempted and reverted due
to 4-byte alignment shift cost.

3. **Clamp slow-path pad increase** (0 cyc in benchmark): Increased the
   dead-code pad between `BCC tg_clamp_done` and `tg_clamp_slow` from
   1 to 2 bytes. Fixes 2 page crossings ($26FF BEQ and $29FF BCC) that
   fire when new seg values need clamping from off-screen. Zero new
   crossings. +1 byte ROM.

**Final**: S1=36,782 S2=110,438 Grand=**147,220** ROM=2,950 bytes
Delta from carry round: **−81 cycles (−0.06%)**

## Optimisation ideas (not yet attempted)

- `interp_store`/`seg_interp_store` could short-circuit the small-positive
  case too, but the round-to-nearest bias makes the check more involved
  (need to compare `prod` to `den/2`, with care around odd `den`).
- The 17 udiv16_8 skip-loop BCS page crossings ($20xx→$21xx) are the
  largest remaining target, but all restructuring approaches introduce
  crossing in the main loop or dskip_commit paths. A clean fix would
  require ~61 bytes of code relocation (moving span_init) plus ~14-28
  bytes of alignment padding, with unpredictable net effect.
- Further JMP→branch conversions are limited: most remaining JMPs in
  mark_solid and tighten exceed the 128-byte branch range. Flag-state
  analysis must be rigorous (STX/STA do NOT set flags on 6502).

## Total clip+render cycles

Once the clipper gained integrated line emission (tighten/mark_solid
edges + `draw_clipped_line`) with tail-calls into the NJ rasteriser,
the "clip cycles" number above stopped capturing the full cost the
6502 pays per frame. This section tracks `sc.total_cycles` across one
`packed_render_bsp` of each scene — i.e. the sum of every cycle spent
in span_clip.asm and in the NJ rasteriser (`linedraw_or_reloc.bin`
@ $A900) combined.

Measured via `span_clip_6502.SpanClip6502.total_cycles` counter,
which accumulates `mpu.processorCycles` across every entry
(mark_solid, tighten, has_gap, is_full, draw_clipped_line), including
the tail-called rasteriser runs that each emission triggers.

### Reproducing

```bash
python3 - <<'EOF'
import os, math, random
os.environ['SDL_VIDEODRIVER'] = 'dummy'
import pygame; pygame.init(); pygame.display.set_mode((1, 1))
import doom_wireframe as dw
from fp import PRESCALE, MAP_CENTER_X, MAP_CENTER_Y, fp_sincos, fp_view_context
from wad_packed import spans_init_full
from endpoint_spans import EndpointClipSpans, _compute_tighten_splits
from span_clip_6502 import SpanClip6502

sc = SpanClip6502()

class Inst(EndpointClipSpans):
    def __init__(self):
        super().__init__(); sc.clear_screen(); sc.init()
    def mark_solid(self, lo, hi, sx1=None, sx2=None, yt1=None, yt2=None,
                   yb1=None, yb2=None):
        super().mark_solid(lo, hi)
        sc.mark_solid(lo, hi, sx1=sx1, sx2=sx2, yt1=yt1, yt2=yt2,
                      yb1=yb1, yb2=yb2)
    def tighten(self, lo, hi, sx1, sx2, yt1, yt2, yb1, yb2,
                top_dom=False, bot_dom=False, emit_top=True, emit_bot=True):
        for i, params in enumerate(_compute_tighten_splits(
                lo, hi, sx1, sx2, yt1, yt2, yb1, yb2)):
            super().tighten(*params, top_dom=top_dom, bot_dom=bot_dom)
            if i == 0:
                sc.tighten(*params, emit_top=emit_top, emit_bot=emit_bot)
            else:
                sc.tighten(*params, emit_top=False, emit_bot=False)
    def has_gap(self, lo, hi):
        r = super().has_gap(lo, hi); sc.has_gap(lo, hi); return r
    def is_full(self):
        r = super().is_full(); sc.is_full(); return r
    def draw_clipped(self, lines, color, surface, stats=None):
        for lx1, ly1, lx2, ly2 in lines:
            if lx1 != lx2:
                sc.draw_clipped_line(lx1, ly1, lx2, ly2)
        super().draw_clipped(lines, color, surface, stats)

SCENES = [('S1', 1056, -3616, 64), ('S2', 505, -3268, 125)]
grand = 0
for name, px, py, ab in SCENES:
    ang_rad = ab * 2 * math.pi / 256
    cos_f = math.cos(ang_rad); sin_f = math.sin(ang_rad)
    px_88 = int((px - MAP_CENTER_X) * 256 / PRESCALE)
    py_88 = int((py - MAP_CENTER_Y) * 256 / PRESCALE)
    vz_ps = dw._prescale_height(dw.player_floor(px, py) + 41)
    ctx = fp_view_context(px_88, py_88, fp_sincos(ab))
    p_ram = dw._packed_ram_new()
    spans_init_full(p_ram, dw.packed_layout['ram_spans'],
                    dw.FP_RENDER_W, dw.FP_RENDER_H - 1)
    inst = Inst()
    random.seed(42)
    for i in range(5): dw.draw_stats[i] = 0
    for k in dw.map_trace:
        dw.map_trace[k] = {} if k == 'vertex_muls' else (
            [] if k == 'ss_order' else set())
    sc.total_cycles = 0
    dw.packed_render_bsp(len(dw.nodes)-1, inst, ctx, vz_ps,
                         int(px), int(py), cos_f, sin_f,
                         pygame.Surface((256, 160)), p_ram)
    print(f'{name} ({px},{py},{ab}): {sc.total_cycles} clip+render cyc')
    grand += sc.total_cycles
print(f'GRAND TOTAL: {grand}')
EOF
```

### History

| Date       | span_clip.bin | **S1 clip+render** | Δ | **S2 clip+render** | Δ | **Grand** | Δ | Notes |
|------------|--------------:|-------------------:|---:|-------------------:|---:|----------:|---:|-------|
| 2026-04-16 |       6053 B  | **166436**         |       | **281767**         |       | **448203**|       | Baseline after mel crossover-clip fix (commit af70142). Includes DCL and all tail-called NJ rasteriser work. |
| 2026-04-17 |       6175 B  | **165163**         | −1273 | **280491**         | −1276 | **445654**| −2549 | **Span pool block layout + precomputed bbox.** Pool refactored from interleaved 9-byte slots (28 max, X=slot×9) to block layout (13 fields × 32 slots, X=slot index). Added POOL_OT/OB/IT/IB precomputed at 7 write sites; 4 consumer sites (tighten old-dom/new-dom BB, portal continuation, DCL bbox) now use direct loads instead of inline min/max. ROM +122 B, pool RAM $0400–$059F. |
| 2026-04-17 |       6085 B  | **156346**         | −8817 | **270099**         | −10392| **426445**| −19209| **DCL micro-opts + CB clip bbox filters.** (1) Inline dcl_advance at 7 sites (−3-6 cyc per advance). (2) Portal/exit BIT tricks: dy==0 routes to yr; 3-way→2-way convergence. (3) dcl_accept BIT merge from portal tier 3 pattern. (4) JMP→BCS via carry analysis. (5) CB clip: skip top eval+clip entirely when both cy≥IT; skip bot when both cy≤IB. Splits combined 4-boundary eval into separate top-only / bot-only phases with own den=0 / constant / interp fast paths. ROM −90 B from session start. |
| 2026-04-18 |       6051 B  | **154403**         | −1943 | **268351**         | −1748 | **422754**| −3691 | **Unsigned interp restructure + DCL micro-opts.** (1) interp_store and line_interp_store split on y1 vs y0 direction: always compute |dy| unsigned, use umul8 (never smul8). Eliminates BMI is_neg check, product negate, and biased rounding. Shared umul_round_div helper (umul8 + round + tail-call udiv16_8). Python reference split: `_interp_store` (new formula) for u8 spans, `_interp_store_s16` (old formula) for s16 seg values. 0/320 wide-test span mismatches. (2) CB clip cy recompute: boundary_y(ix) via span interp workspace instead of dcl_line_y_at_a shuffle. Constant spans skip interp entirely. (3) Dead cy endpoint checks removed (−96 B). (4) POOL_DEN replaces POOL_XHI. (5) line_interp_store reads line params directly. (6) LDY/STY shuffle + fall-through. |
| 2026-04-18 |       6107 B  | **155627**         | +1224 | **276081**         | +7730 | **431708**| +8954 | **Y_BIAS=48 pre-clip.** Bias all Y coordinates so visible [0,159] maps to [48,207] within u8. span_init sets biased boundaries. 18 raster Y writes un-bias with `SEC : SBC #Y_BIAS`. Python wrapper biases at Instrumented6502Spans boundary. Enables future s16→u8 simplification. ROM +56 B. |
| 2026-04-18 |       6029 B  | **154033**         | −1594 | **274997**         | −1084 | **429030**| −2678 | **Fix clamp thresholds for Y_BIAS.** Clamp [0,159] was wrong for biased range — corrupted valid values in [160,207]. Changed clamp fast path: when all s16 hi bytes are 0, skip clamping entirely (BEQ tg_clamp_done). Slow-path clamp targets updated to VIS_YMAX=207. tg_newdom_fast sentinel updated. Python reference _clamp8/_tighten clamp updated to [0,207]. ROM −78 B. |
| 2026-04-18 |       5812 B  | **151800**         | −2233 | **229869**         | −45128| **381669**| −47361| **Replace seg_interp_store with interp_store (u8).** All 14 seg_interp_store call sites converted to unsigned u8 interp_store. Eliminates smul8 (signed multiply), s16 division tail, hi-byte ZP setup/store. Constant-line fast paths and anchor fast paths stripped of s16 hi-byte handling. Cache stores lo bytes only. seg_interp_store+smul8 deleted (dead code). Python reference tighten uses `_interp_store` (unsigned) instead of `_interp_store_s16`. The unsigned formula produces different rounding at crossover boundaries → fewer crossover splits in S2 → large cycle saving. ROM −217 B cumulative from Y_BIAS start. |
