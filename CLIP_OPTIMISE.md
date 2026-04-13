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

Per-call averages (S1): `mark_solid` 191, `tighten` 2327, `has_gap` 51, `is_full` 16.
Per-call averages (S2): `mark_solid` 231, `tighten` 1771, `has_gap`  63, `is_full` 16.

Cumulative vs baseline (S1 127 389 cyc → 40 377): **−87 012 cyc, −68.3%**.
ROM size: 2701 → 3325 bytes, **+624 bytes**.

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

## Optimisation ideas (not yet attempted)

- `interp_store`/`seg_interp_store` could short-circuit the small-positive
  case too, but the round-to-nearest bias makes the check more involved
  (need to compare `prod` to `den/2`, with care around odd `den`).
- A page-aligned `span_has_gap` would save ~2 cycles per call by avoiding
  the page-cross BNE on the loop back-edge. Would cost up to 46 padding
  bytes of ROM.
