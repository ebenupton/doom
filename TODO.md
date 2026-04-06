# TODO

## 1-pixel clipping divergence in NE view
- verify_lines.py: spawn NE line 5 has inner_top=62 (6502) vs 63 (Python)
- Same diff at both PRESCALE=8 and PRESCALE=16
- Likely a span state timing difference: the peripheral reads spans from
  native RAM ($20D0) while the Python reference maintains its own FPClipSpans
- Investigate whether the native flush produces a different inner_top for
  the span overlapping x=82/84 at the point this seg is drawn
- May be related to the order of tighten operations within a subsector
