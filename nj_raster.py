"""Pure-Python port of the NJ linedraw4 rasteriser — pixel-exact vs the 6502.

Draws into a 5120-byte BBC mode-4 framebuffer (the exact $5800 screen layout:
byte = (y>>3)*256 + (x & 0xF8) + (y & 7), bit = 0x80 >> (x & 7)), OR-mode.

Transliterated from raster/nj-linedraw4-or.asm:
  - endpoint sort: ensure y0 >= y1 (draw bottom-to-top); direction from the
    x comparison AFTER the sort (x0 >= x1 -> left-going).
  - shallow (dx >= dy): run-accumulating core. err starts at dx>>1; per bit,
    err -= dy; on borrow the accumulated run [start..cur] is plotted at the
    current row and err += dx; cnt counts y-steps (dy of them), then the
    e-phase (ls=2) does err -= errs (= dx>>1) and, if no borrow, one more
    run row (cnt=1) — matching the asm's eN0 blocks exactly. Byte-end splits
    plot the partial run and continue accumulation in the next byte.
  - horizontal is the shallow core with cnt=ls=1, dy=1, err=dx (the asm's
    .horizontal patch): the whole row emerges as byte-split runs.
  - steep (dx < dy): per-pixel core. r starts at dy>>1; per row, r -= dx; on
    borrow r += dy and the column advances (mask shift with byte cross);
    cnt counts x-steps (dx), then the same ls=2 e-phase with errs = dy>>1.
    Vertical is the steep core with cnt=ls=1, step=1, r=dy.

The pixel-for-pixel contract is enforced by tools/nj_raster_check.py against
the 42,462-line golden corpus (build/raster_ab.json) hashed from the 6502.
"""

FB_SIZE = 5120


def new_fb():
    return bytearray(FB_SIZE)


def _plot_bits(fb, xbyte, row, blo, bhi):
    """OR bits blo..bhi (bit indices, 0 = leftmost pixel = mask $80) of the
    byte at pixel-x base `xbyte`, row `row`."""
    mask = 0
    for b in range(blo, bhi + 1):
        mask |= 0x80 >> b
    fb[((row >> 3) << 8) + (xbyte & 0xF8) + (row & 7)] |= mask


def draw_line(fb, x0, y0, x1, y1):
    # --- endpoint sort: y0 >= y1 (bottom-to-top) ---
    if y0 < y1:
        dy = y1 - y0
        x0, x1 = x1, x0
        y0 = y1
    else:
        dy = y0 - y1
    left = x0 >= x1
    dx = (x0 - x1) if left else (x1 - x0)

    if dx >= dy:
        # --- shallow ---
        if dy == 0:
            err = dx
            errs = 0            # never read (ls==1 exits the e-phase first)
            cnt = 1
            ls = 1
        else:
            err = errs = dx >> 1
            cnt = dy
            ls = 2
        _shallow(fb, x0, y0, dx, dy if dy else 1, left, err, errs, cnt, ls)
    else:
        # --- steep ---
        if dx == 0:
            cnt = 1
            ls = 1
            errs = dy
            step = 1
        else:
            cnt = dx
            ls = 2
            errs = dy >> 1
            step = dx
        _steep(fb, x0, y0, step, dy, left, errs, errs, cnt, ls)


def _shallow(fb, x0, y0, dx, dy, left, err, errs, cnt, ls):
    row = y0
    xbyte = x0 & 0xF8
    bit = x0 & 7
    acc = bit                   # run-start bit within the current byte
    while True:
        err -= dy
        if err >= 0:
            # no y-step: extend the run to the next bit
            if left:
                if bit == 0:
                    _plot_bits(fb, xbyte, row, 0, acc)   # byte end: flush
                    xbyte -= 8
                    bit = acc = 7
                else:
                    bit -= 1
            else:
                if bit == 7:
                    _plot_bits(fb, xbyte, row, acc, 7)   # byte end: flush
                    xbyte += 8
                    bit = acc = 0
                else:
                    bit += 1
            continue
        # y-step: plot the accumulated run at this row
        err += dx
        if left:
            _plot_bits(fb, xbyte, row, bit, acc)
        else:
            _plot_bits(fb, xbyte, row, acc, bit)
        cnt -= 1
        if cnt == 0:
            ls -= 1
            if ls == 0:
                return
            err -= errs
            if err < 0:
                return
            cnt = 1
        # row step + advance to the next bit (fN0 continuation)
        row -= 1
        if left:
            if bit == 0:
                xbyte -= 8
                bit = 7
            else:
                bit -= 1
        else:
            if bit == 7:
                xbyte += 8
                bit = 0
            else:
                bit += 1
        acc = bit


def _steep(fb, x0, y0, step, dy, left, r, errs, cnt, ls):
    row = y0
    xbyte = x0 & 0xF8
    bit = x0 & 7
    while True:
        fb[((row >> 3) << 8) + xbyte + (row & 7)] |= 0x80 >> bit
        r -= step
        if r >= 0:
            row -= 1
            continue
        # x-step
        r += dy
        cnt -= 1
        if cnt == 0:
            ls -= 1
            if ls == 0:
                return
            r -= errs
            if r < 0:
                return
            cnt = 1
        # advance column, then row (nr continuation)
        if left:
            if bit == 0:
                xbyte -= 8
                bit = 7
            else:
                bit -= 1
        else:
            if bit == 7:
                xbyte += 8
                bit = 0
            else:
                bit += 1
        row -= 1
